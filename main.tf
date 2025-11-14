locals {
  name = "devops-3tier"
}

# 1) VPC + subnets + IGW + route
resource "aws_vpc" "this" {
  cidr_block = var.vpc_cidr
  tags = { Name = "${local.name}-vpc" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.this.id
  tags = { Name = "${local.name}-igw" }
}

# Create public subnets
resource "aws_subnet" "public" {
  for_each = { for idx, cidr in var.public_subnets : tostring(idx) => cidr }
  vpc_id = aws_vpc.this.id
  cidr_block = each.value
  map_public_ip_on_launch = true
  availability_zone = data.aws_availability_zones.available.names[tonumber(each.key)]
  tags = { Name = "${local.name}-public-${each.key}" }
}

# Create private subnets
resource "aws_subnet" "private" {
  for_each = { for idx, cidr in var.private_subnets : tostring(idx) => cidr }
  vpc_id = aws_vpc.this.id
  cidr_block = each.value
  map_public_ip_on_launch = false
  availability_zone = data.aws_availability_zones.available.names[tonumber(each.key)]
  tags = { Name = "${local.name}-private-${each.key}" }
}

data "aws_availability_zones" "available" {}

# Route table for public
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = { Name = "${local.name}-public-rt" }
}

resource "aws_route_table_association" "pub_assoc" {
  for_each = aws_subnet.public
  subnet_id = each.value.id
  route_table_id = aws_route_table.public.id
}

# 2) Security Groups

# ALB SG
resource "aws_security_group" "alb_sg" {
  name   = "${local.name}-alb-sg"
  vpc_id = aws_vpc.this.id
  description = "Allow HTTP from internet"
  ingress {
    from_port = 80
    to_port   = 80
    protocol  = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port = 443
    to_port   = 443
    protocol  = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "${local.name}-alb-sg" }
}

# Web SG (allow inbound from ALB SG only)
resource "aws_security_group" "web_sg" {
  name   = "${local.name}-web-sg"
  vpc_id = aws_vpc.this.id
  description = "Allow inbound traffic from ALB"
  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id]
  }
  ingress {
    from_port = 22
    to_port   = 22
    protocol  = "tcp"
    cidr_blocks = ["54.90.119.117/32"] # replace with your IP or restrict SSH
  }
  egress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "${local.name}-web-sg" }
}

# RDS SG (allow inbound from web_sg)
resource "aws_security_group" "rds_sg" {
  name   = "${local.name}-rds-sg"
  vpc_id = aws_vpc.this.id
  description = "Allow MySQL from web SG only"
  ingress {
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.web_sg.id]
  }
  egress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "${local.name}-rds-sg" }
}

# 3) ALB, target group, listener
resource "aws_lb" "alb" {
  name               = "${local.name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = values(aws_subnet.public)[*].id
  tags = { Name = "${local.name}-alb" }
}

resource "aws_lb_target_group" "tg" {
  name     = "${local.name}-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.this.id
  health_check {
    path = "/"
    interval = 30
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.alb.arn
  port              = "80"
  protocol          = "HTTP"
  default_action {
    type = "forward"
    target_group_arn = aws_lb_target_group.tg.arn
  }
}

# 4) Launch Template + Auto Scaling Group (simple)
data "template_file" "user_data" {
  template = file("${path.module}/user_data.sh.tpl")
  vars = {
    db_endpoint = aws_db_instance.this.address
    db_name     = aws_db_instance.this.db_name
    db_user     = aws_db_instance.this.username
    # password is passed via userdata only for demo (better: use secrets manager)
    db_pass     = var.db_password
  }
}

resource "aws_launch_template" "lt" {
  name_prefix   = "${local.name}-lt-"
  image_id      = "ami-0c398cb65a93047f2"
  instance_type = var.instance_type
  user_data     = base64encode(data.template_file.user_data.rendered)
  vpc_security_group_ids = [aws_security_group.web_sg.id]
}

resource "aws_autoscaling_group" "asg" {
  name                      = "${local.name}-asg"
  max_size                  = 2
  min_size                  = 1
  desired_capacity          = 1
  vpc_zone_identifier       = values(aws_subnet.public)[*].id
  launch_template {
    id      = aws_launch_template.lt.id
    version = "$Latest"
  }
  target_group_arns = [aws_lb_target_group.tg.arn]
  tag {
    key                 = "JAS"
    value               = "${local.name}-web"
    propagate_at_launch = true
  }
}

# 5) RDS (MySQL) in private subnet
resource "aws_db_subnet_group" "default" {
  name       = "${local.name}-db-subnet-group"
  subnet_ids = values(aws_subnet.private)[*].id
  tags = { Name = "${local.name}-db-subnet-group" }
}

resource "aws_db_instance" "this" {
  allocated_storage    = 20
  engine               = "mysql"
  engine_version       = "8.0"
  instance_class       = "db.t3.micro"
  db_name                 = "appdb"
  username             = "dbadmin"
  password             = var.db_password
  skip_final_snapshot  = true
  db_subnet_group_name = aws_db_subnet_group.default.name
  vpc_security_group_ids = [aws_security_group.rds_sg.id]
  publicly_accessible  = false
  tags = { Name = "${local.name}-rds" }
}

