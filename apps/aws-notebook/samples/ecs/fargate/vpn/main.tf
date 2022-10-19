terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.0"
    }
  }
}

# Configure the AWS Provider
provider "aws" {
  region = "us-west-1"
}

data "external" "tls" {
  program = ["./prepare_openvpn_cert.sh"]
}

data "external" "vpn_client" {
  program = ["./build_openvpn_config.sh"]

  query = {
    vpn_server_dns = aws_ec2_client_vpn_endpoint.dev-connection-ecs-fargate-vpn.dns_name
  }
}


data "aws_iam_role" "ecs_task_execution_role" {
  name = "ecsTaskExecutionRole"
}

# Create ECS cluster hosted on Fargate
resource "aws_ecs_cluster" "dev-connection-ecs-fargate-vpn" {
  name = "crafting-notebook-demo"

  setting {
    name  = "containerInsights"
    value = "disabled"
  }
}

# Create a VPC for ECS cluster
resource "aws_vpc" "dev-connection-ecs-fargate-vpn" {
  cidr_block = "10.0.0.0/16"
  enable_dns_support = true
  enable_dns_hostnames = true
  tags = {
    Name = "dev-connection-ecs-fargate-vpn"
  }
}

# Create a subnet for VPC
resource "aws_subnet" "dev-connection-ecs-fargate-vpn" {
  vpc_id     = aws_vpc.dev-connection-ecs-fargate-vpn.id
  cidr_block = "10.0.0.0/17"

  tags = {
    Name = "dev-connection-ecs-fargate-vpn-subnet-a"
  }
}

# Create a task definition 
resource "aws_ecs_task_definition" "dev-connection-ecs-fargate-vpn" {
  family = "dev-connection-ecs-fargate-vpn"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu = 256
  memory = 512
  runtime_platform {
      operating_system_family = "LINUX"
      cpu_architecture        = "X86_64"
  }
  task_role_arn            = "${data.aws_iam_role.ecs_task_execution_role.arn}"
  execution_role_arn       = "${data.aws_iam_role.ecs_task_execution_role.arn}"
  container_definitions = jsonencode([
    {
      name      = "ssh-server"
      image     = "926120211684.dkr.ecr.us-west-1.amazonaws.com/dev/tzz/ssh-server:latest"
      essential = true
      portMappings = [
        {
          containerPort = 2222
          hostPort      = 2222
        }
      ]
    }
  ])
}

## Create ECS service
resource "aws_ecs_service" "dev-connection-ecs-fargate-vpn"{
 launch_type = "FARGATE"
 task_definition = aws_ecs_task_definition.dev-connection-ecs-fargate-vpn.arn
 name = "dev-connection-ecs-fargate-vpn-ssh-server"
 cluster = aws_ecs_cluster.dev-connection-ecs-fargate-vpn.id
 scheduling_strategy = "REPLICA"
 desired_count = 1
 network_configuration  {
   subnets = [aws_subnet.dev-connection-ecs-fargate-vpn.id]
 }
}



# Create PrivateLink to access ECR without internet connection
resource "aws_vpc_endpoint" "dev-connection-ecs-fargate-vpn-s3"{
  vpc_id = aws_vpc.dev-connection-ecs-fargate-vpn.id
  service_name =  "com.amazonaws.us-west-1.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids = [aws_vpc.dev-connection-ecs-fargate-vpn.main_route_table_id]

  tags = {
    Name = "dev-connection-ecs-fargate-vpn-s3"
  }
}

resource "aws_vpc_endpoint" "dev-connection-ecs-fargate-vpn-ecr-dkr"{
  vpc_id = aws_vpc.dev-connection-ecs-fargate-vpn.id
  service_name =  "com.amazonaws.us-west-1.ecr.dkr"
  vpc_endpoint_type = "Interface"
  private_dns_enabled = true
  subnet_ids = [aws_subnet.dev-connection-ecs-fargate-vpn.id]

  tags = {
    Name = "dev-connection-ecs-fargate-vpn-ecr-dkr"
  }
}

resource "aws_vpc_endpoint" "dev-connection-ecs-fargate-vpn-ecr-api"{
  vpc_id = aws_vpc.dev-connection-ecs-fargate-vpn.id
  service_name =  "com.amazonaws.us-west-1.ecr.api"
  vpc_endpoint_type = "Interface"
  private_dns_enabled = true
  subnet_ids = [aws_subnet.dev-connection-ecs-fargate-vpn.id]

  tags = {
    Name = "dev-connection-ecs-fargate-vpn-ecr-api"
  }
}

resource "aws_vpc_endpoint" "dev-connection-ecs-fargate-vpn-logs"{
  vpc_id = aws_vpc.dev-connection-ecs-fargate-vpn.id
  service_name =  "com.amazonaws.us-west-1.logs"
  vpc_endpoint_type = "Interface"
  private_dns_enabled = true
  subnet_ids = [aws_subnet.dev-connection-ecs-fargate-vpn.id]

  tags = {
    Name = "dev-connection-ecs-fargate-vpn-logs"
  }
}

resource "aws_acm_certificate" "cert" {
  private_key      = file(data.external.tls.result.server_key)
  certificate_body = file(data.external.tls.result.server_cert)

  certificate_chain = file(data.external.tls.result.ca_cert)
}

#data "aws_acm_certificate" "dev-connection-ecs-fargate-vpn" {
#  domain   = "notebook.server.crafting.demo"
#  statuses = ["ISSUED"]
#}

# Create Client VPN Endpoint
resource "aws_ec2_client_vpn_endpoint" "dev-connection-ecs-fargate-vpn" {
  client_cidr_block = "172.17.0.0/16"
  server_certificate_arn =  aws_acm_certificate.cert.arn
   authentication_options {
    type                       = "certificate-authentication"
    root_certificate_chain_arn = aws_acm_certificate.cert.arn
  }
   connection_log_options {
    enabled               = false
  }

  tags = {
    Name = "dev-connection-ecs-fargate-vpn"
  }
}

# Associate subnet with Client VPN endpoint
resource "aws_ec2_client_vpn_network_association" "dev-connection-ecs-fargate-vpn" {
  client_vpn_endpoint_id = aws_ec2_client_vpn_endpoint.dev-connection-ecs-fargate-vpn.id
  subnet_id              = aws_subnet.dev-connection-ecs-fargate-vpn.id
}

# Add Authorization Rule to Client VPN endpoint
resource "aws_ec2_client_vpn_authorization_rule" "dev-connection-ecs-fargate-vpn" {
  client_vpn_endpoint_id = aws_ec2_client_vpn_endpoint.dev-connection-ecs-fargate-vpn.id
  target_network_cidr    = aws_subnet.dev-connection-ecs-fargate-vpn.cidr_block
  authorize_all_groups   = true
}

