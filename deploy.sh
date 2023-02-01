#!/bin/bash
echo "Desplegando VPC de servicio..."
aws cloudformation deploy --template-file vpc/vpc.yaml --stack-name service  --parameter-overrides file://vpc/service-vpc.json --region us-east-1
echo "VPC de servicio desplegada correctamente"
echo "Desplegando VPC de cliente..."
aws cloudformation deploy --template-file vpc/vpc.yaml --stack-name client --parameter-overrides file://vpc/client-vpc.json --region us-east-1
echo "VPC de cliente desplegada correectamente"
echo "Creando imagen de Docker para contenedor Squid..."
docker build -t proxy-squid:latest squid/.
echo "Imagen de contenedor Squid personalizada creada..."
echo "Creando repositorio de Amazon ECR..."
repo=$(aws ecr create-repository --repository-name proxy-squid --region us-east-1 --query repository.repositoryUri --output text)
echo "Repositorio de Amazon ECR creado. Autenticando con el registro de Amazon ECR..."
docker login -u AWS -p $(aws ecr get-login-password --region us-east-1) $repo
echo "Etiquetando la imagen del contenedor..."
docker tag proxy-squid:latest $repo:latest
echo "Enviando imagen del contenedor a Amazon ECR..."
docker push $repo:latest
LabRole=$(aws iam get-role --role-name LabRole --query Role.Arn --output text)
sed -i 's|<imagen>|'$repo'|g' ./ecs-task/definicion-tarea.json
sed -i 's|<LabRole>|'$LabRole'|g' ./ecs-task/definicion-tarea.json
echo "Registrando la definicion de tarea en Amazon ECR..."
aws ecs register-task-definition --cli-input-json file://ecs-task/definicion-tarea.json --region us-east-1
echo "Creando grupo de logs /ecs/squid-task ..."
aws logs create-log-group --log-group-name /ecs/squid-task --region us-east-1
echo "Creando el cluster de Amazon ECS..."
aws ecs create-cluster --cluster-name proxy-cluster --region us-east-1
privada1=$(aws cloudformation describe-stacks --stack-name service --query 'Stacks[0].Outputs[?OutputKey==`Privada1`].OutputValue' --output text --region us-east-1)
privada2=$(aws cloudformation describe-stacks --stack-name service --query 'Stacks[0].Outputs[?OutputKey==`Privada2`].OutputValue' --output text --region us-east-1)
echo "Creando el balanceador de carga de red..."
nlb=$(aws elbv2 create-load-balancer --name proxy-nlb --type network --subnets $privada1 $privada2 --scheme internal --query LoadBalancers[].LoadBalancerArn --output text --region us-east-1)
aws elbv2 wait load-balancer-available --region us-east-1
aws elbv2 modify-load-balancer-attributes --load-balancer-arn $nlb --attributes Key=load_balancing.cross_zone.enabled,Value=true --region us-east-1
vpc=$(aws cloudformation describe-stacks --stack-name service --query 'Stacks[0].Outputs[?OutputKey==`VPC`].OutputValue' --output text --region us-east-1)
echo "Creando grupo de seguridad para las tareas de contenedores Squid..."
proxysg=$(aws ec2 create-security-group --group-name service-proxy-sg --description "Trafico 3128 TCP" --vpc-id $vpc --output text --query GroupId --region us-east-1)
aws ec2 authorize-security-group-ingress --group-id $proxysg --protocol tcp --port 3128 --cidr 0.0.0.0/0 --region us-east-1
echo "Creando el grupo de destinos..."
proxytg=$(aws elbv2 create-target-group --name proxy-tg --protocol TCP --port 3128 --vpc-id $vpc --health-check-interval 15 --healthy-threshold-count 2 --target-type ip --query TargetGroups[].TargetGroupArn --output text --region us-east-1)
sed -i 's|<proxy-tg>|'$proxytg'|g' ./ecs-service/listener.json
echo "Creando el listener del balanceador por el puerto TCP 3128..."
aws elbv2 create-listener --load-balancer-arn $nlb --protocol TCP --port 3128 --default-actions file://ecs-service/listener.json --region us-east-1
sed -i 's|<proxy-tg>|'$proxytg'|g' ./ecs-service/servicio.json
sed -i 's|<proxy-sg>|'$proxysg'|g' ./ecs-service/servicio.json
sed -i 's|<proxy-subnets>|'$privada1\",\"$privada2'|g' ./ecs-service/servicio.json
echo "Creando el servicio en Amazon ECS..."
aws ecs create-service --cli-input-json file://ecs-service/servicio.json --region us-east-1
echo "Configurando el escalado del servicio en AWS AutoScaling..."
aws application-autoscaling register-scalable-target --service-namespace ecs --resource-id service/proxy-cluster/proxy-service --scalable-dimension ecs:service:DesiredCount --min-capacity 2 --max-capacity 10 --region us-east-1
aws application-autoscaling put-scaling-policy --policy-name escalado-proxy --service-namespace ecs --resource-id service/proxy-cluster/proxy-service --scalable-dimension ecs:service:DesiredCount --policy-type TargetTrackingScaling --target-tracking-scaling-policy-configuration file://ecs-service/politica-escalado.json --region us-east-1
echo "Creando el servicio de punto de enlace..."
servicio=$(aws ec2 create-vpc-endpoint-service-configuration --network-load-balancer-arn $nlb --output text --query ServiceConfiguration.ServiceName --region us-east-1)
vpcCliente=$(aws cloudformation describe-stacks --stack-name client --query 'Stacks[0].Outputs[?OutputKey==`VPC`].OutputValue' --output text --region us-east-1)
echo "Creando un grupo de seguridad para el punto de enlace ..."
endpointsg=$(aws ec2 create-security-group --group-name proxy-endpoint-sg --description "Trafico 3128 TCP" --vpc-id $vpcCliente --output text --query GroupId --region us-east-1)
aws ec2 authorize-security-group-ingress --group-id $endpointsg --protocol tcp --port 3128 --cidr 0.0.0.0/0 --region us-east-1
privadaCliente1=$(aws cloudformation describe-stacks --stack-name client --query 'Stacks[0].Outputs[?OutputKey==`Privada1`].OutputValue' --output text --region us-east-1)
privadaCliente2=$(aws cloudformation describe-stacks --stack-name client --query 'Stacks[0].Outputs[?OutputKey==`Privada2`].OutputValue' --output text --region us-east-1)
echo "Creando el punto de enlace..."
endpointdns=$(aws ec2 create-vpc-endpoint --vpc-endpoint-type Interface --vpc-id $vpcCliente --service-name $servicio --subnet-ids $privadaCliente1 $privadaCliente2 --security-group-ids $endpointsg --query VpcEndpoint.DnsEntries[0].DnsName --output text --region us-east-1)
echo "Creando el grupo de seguridad para las instancias EC2 en la VPC cliente..."
clientsg=$(aws ec2 create-security-group --group-name client-sg --description "Trafico salida 3128 y 443 TCP" --vpc-id $vpcCliente --output text --query GroupId --region us-east-1)
aws ec2 authorize-security-group-egress --group-id $clientsg --protocol tcp --port 3128 --cidr 0.0.0.0/0 --region us-east-1
aws ec2 revoke-security-group-egress --group-id $clientsg --protocol all --cidr 0.0.0.0/0 --region us-east-1
sed -i 's|<punto-enlace>|'$endpointdns'|g' ./client/userdata.sh
aws ec2 run-instances --image-id resolve:ssm:/aws/service/ami-amazon-linux-latest/amzn2-ami-hvm-arm64-gp2 --instance-typ t4g.small --security-group-ids sg-0e39524be646f9992 --subnet-id subnet-0d2378ad50d6d1365 --iam-instance-profile Arn=$profile,Name=LabInstanceProfile --user-data file://client/userdata.sh --region us-east-1
