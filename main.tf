terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "eu-north-1" # Stockholm
}

# 1. Fetch latest Amazon Linux 2023 AMI dynamically
data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
}

# -----------------------------------------------------------
# 2. Main Software VPC (10.0.0.0/16)
# -----------------------------------------------------------
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  tags = { Name = "Software-VPC" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
}

resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.${count.index + 1}.0/24"
  availability_zone       = element(["eu-north-1a", "eu-north-1b"], count.index)
  map_public_ip_on_launch = true
  tags = { Name = "Public-Subnet-${count.index + 1}" }
}

# -----------------------------------------------------------
# 3. Private / Customer VPC (11.0.0.0/16) & Peering
# -----------------------------------------------------------
resource "aws_vpc" "customer" {
  cidr_block           = "11.0.0.0/16"
  enable_dns_hostnames = true
  tags = { Name = "Customer-VPC" }
}

resource "aws_subnet" "customer_private" {
  vpc_id            = aws_vpc.customer.id
  cidr_block        = "11.0.1.0/24"
  availability_zone = "eu-north-1a"
  tags = { Name = "Customer-Private-Subnet" }
}

resource "aws_vpc_peering_connection" "peering" {
  vpc_id      = aws_vpc.main.id
  peer_vpc_id = aws_vpc.customer.id
  auto_accept = true
  tags        = { Name = "VPC-Peering-Main-Customer" }
}

resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  route {
    cidr_block                = "11.0.0.0/16"
    vpc_peering_connection_id = aws_vpc_peering_connection.peering.id
  }
}

resource "aws_route_table_association" "a" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public_rt.id
}

resource "aws_route_table" "customer_rt" {
  vpc_id = aws_vpc.customer.id

  route {
    cidr_block                = "10.0.0.0/16"
    vpc_peering_connection_id = aws_vpc_peering_connection.peering.id
  }
}

resource "aws_route_table_association" "customer_assoc" {
  subnet_id      = aws_subnet.customer_private.id
  route_table_id = aws_route_table.customer_rt.id
}

# -----------------------------------------------------------
# 4. Security Groups
# -----------------------------------------------------------
resource "aws_security_group" "lb_sg" {
  name   = "lb-sg"
  vpc_id = aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "ec2_sg" {
  name   = "ec2-sg"
  vpc_id = aws_vpc.main.id

  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.lb_sg.id]
  }

  ingress {
    from_port   = -1
    to_port     = -1
    protocol    = "icmp"
    cidr_blocks = ["11.0.0.0/16"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "customer_sg" {
  name   = "customer-sg"
  vpc_id = aws_vpc.customer.id

  ingress {
    from_port   = -1
    to_port     = -1
    protocol    = "icmp"
    cidr_blocks = ["10.0.0.0/16"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# -----------------------------------------------------------
# 5. Compute (2 Web Servers + 1 Customer VM)
# -----------------------------------------------------------
resource "aws_instance" "web_servers" {
  count                  = 2
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.public[count.index].id
  vpc_security_group_ids = [aws_security_group.ec2_sg.id]

  user_data = <<-EOF
              #!/bin/bash
              dnf update -y
              dnf install -y httpd
              systemctl start httpd
              systemctl enable httpd
              echo "<h1>Response from Web Server ${count.index + 1} (Stockholm)</h1>" > /var/www/html/index.html
              EOF

  tags = { Name = "Web-Server-${count.index + 1}" }
}

resource "aws_instance" "customer_vm" {
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.customer_private.id
  vpc_security_group_ids = [aws_security_group.customer_sg.id]
  tags                   = { Name = "Customer-Private-Instance" }
}

# -----------------------------------------------------------
# 6. Load Balancer & Target Group
# -----------------------------------------------------------
resource "aws_lb" "lb" {
  name               = "app-lb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.lb_sg.id]
  subnets            = aws_subnet.public[*].id
}

resource "aws_lb_target_group" "tg" {
  name     = "app-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    path                = "/"
    matcher             = "200"
    interval            = 15
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

resource "aws_lb_listener" "listener" {
  load_balancer_arn = aws_lb.lb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tg.arn
  }
}

resource "aws_lb_target_group_attachment" "attach" {
  count            = 2
  target_group_arn = aws_lb_target_group.tg.arn
  target_id        = aws_instance.web_servers[count.index].id
  port             = 80
}

# -----------------------------------------------------------
# 7. Outputs
# -----------------------------------------------------------
output "alb_dns_url" {
  description = "Access the load-balanced servers via this URL"
  value       = "http://${aws_lb.lb.dns_name}"
}