# ===========================
# BROWSERLESS FARGATE
# ===========================
module "label" {
  source     = "github.com/cloudposse/terraform-null-label"
  enabled    = true
  attributes = []
  delimiter  = "-"
  name       = var.name
  namespace  = var.namespace
  stage      = var.stage
  tags       = {}
}

locals {
  browserless_port = 3000
}

resource "aws_lb_target_group" "browserless" {
  name        = module.label.id
  port        = local.browserless_port
  protocol    = "TCP"
  target_type = "ip"
  vpc_id      = var.vpc_id

  health_check {
    healthy_threshold   = 2
    unhealthy_threshold = 2
    interval            = 30
    port                = local.browserless_port
    protocol            = "TCP"
  }
}


resource "aws_lb" "network" {
  name                             = module.label.id
  enable_cross_zone_load_balancing = true
  idle_timeout                     = 60
  internal                         = true
  load_balancer_type               = "network"
  subnets                          = var.subnet_ids
}

resource "aws_lb_listener" "browserless" {
  load_balancer_arn = aws_lb.network.arn
  port              = var.lb_port
  protocol          = "TCP"

  default_action {
    target_group_arn = aws_lb_target_group.browserless.arn
    type             = "forward"
  }
}

resource "aws_security_group" "browserless" {
  name        = module.label.id
  description = "Allow traffic for browserless chrome from alb"
  vpc_id      = var.vpc_id

  ingress {
    description = "Allow traffic to containers"
    from_port   = local.browserless_port
    to_port     = local.browserless_port
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    self        = true
  }

  egress {
    description = "Allow outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = -1
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    "Name" = module.label.id
  }
}

resource "aws_ecs_cluster" "browserless" {
  name = module.label.id
}

module "browserless_container" {
  source    = "github.com/cisagov/fargate-container-def-tf-module"
  namespace = var.namespace
  stage     = var.stage
  name      = var.name

  container_name  = module.label.id
  container_image = "browserless/chrome:latest"
  container_port  = local.browserless_port
  region          = var.region
  log_retention   = 7
  environment     = { "MAX_CONCURRENT_SESSIONS" : 10 }
}

resource "aws_ecs_task_definition" "browserless" {
  family                   = module.label.id
  container_definitions    = module.browserless_container.json
  cpu                      = var.cpu
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  memory                   = var.memory
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  task_role_arn            = aws_iam_role.ecs_task.arn
}

resource "aws_ecs_service" "browserless" {
  name            = module.label.id
  cluster         = aws_ecs_cluster.browserless.id
  task_definition = aws_ecs_task_definition.browserless.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  load_balancer {
    target_group_arn = aws_lb_target_group.browserless.arn
    container_name   = module.label.id
    container_port   = local.browserless_port
  }

  network_configuration {
    subnets          = var.subnet_ids
    security_groups  = [aws_security_group.browserless.id]
    assign_public_ip = false
  }
}


# IAM
data "aws_iam_policy_document" "ecs_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ecs_execution" {
  name               = "${module.label.id}-ecs-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume_role.json
}

data "aws_iam_policy_document" "ecs_execution" {
  statement {
    actions = [
      "logs:*",
      "ssm:Get*"
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "ecs_execution" {
  name        = "${module.label.id}-ecs-execution"
  description = "Policy for ecs execution"
  policy      = data.aws_iam_policy_document.ecs_execution.json
}

resource "aws_iam_role_policy_attachment" "ecs_execution_base" {
  role       = aws_iam_role.ecs_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy_attachment" "ecs_execution_other" {
  role       = aws_iam_role.ecs_execution.name
  policy_arn = aws_iam_policy.ecs_execution.arn
}

resource "aws_iam_role" "ecs_task" {
  name               = "${module.label.id}-ecs-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume_role.json
}
