terraform {
    required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.9"
    }
  }
}

provider aws {
    profile = "default"
    region  = "eu-west-2"
}

provider "kubernetes" {
    host                   = aws_eks_cluster.eks_cluster.endpoint
    cluster_ca_certificate = base64decode(aws_eks_cluster.eks_cluster.certificate_authority[0].data)
    exec {
      api_version = "client.authentication.k8s.io/v1alpha1"
      args        = ["eks", "get-token", "--cluster-name", aws_eks_cluster.eks_cluster.name]
      command     = "aws"
    }
#    token                  = data.aws_eks_cluster_auth.eks_auth.token
#    load_config_file       = false
}

data "aws_availability_zones" "available" {}

locals {
  cluster_name = "training-eks-${random_string.suffix.result}"
}
resource "random_string" "suffix" {
  length  = 8
  special = false
}

#===== VPC config =====

module "vpc" {
  source = "terraform-aws-modules/vpc/aws"
  version = "2.6.0"

  name            = "eks-vpc"
  cidr            = "10.10.0.0/16"
  azs             = ["eu-west-2a", "eu-west-2b"]
#  azs             = data.aws_availability_zones.available.names
  public_subnets  = ["10.10.1.0/24", "10.10.2.0/24"]
#  private_subnets = ["10.10.11.0/24", "10.10.12.0/24"]

#  enable_nat_gateway   = true
#  single_nat_gateway   = true
  enable_dns_hostnames = true
  enable_vpn_gateway   = false

  tags = {
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
  }

  public_subnet_tags = {
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
    "kubernetes.io/role/elb"                      = "1"
  }

  private_subnet_tags = {
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
    "kubernetes.io/role/internal-elb"             = "1"
  }
}

resource "aws_security_group" "wordpress_sg" {
  name = "WordpressSG"
  vpc_id = module.vpc.vpc_id
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description = "External-Service"
    from_port   = 30007
    to_port     = 30007
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description = "DB"
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags ={
    Name = "Wordpress"
  }
}
resource "aws_security_group" "database_sg" {
  name = "DatabaseSG"
  vpc_id = module.vpc.vpc_id
  ingress {
    description = "DB"
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags ={
    Name = "Database"
  }
}

resource "aws_db_subnet_group" "rds_public" {
  name        = "rdsmain-public"
  description = "Public subnets for RDS instance"
  subnet_ids  = module.vpc.public_subnets
}

#===== Database instance =====
resource "aws_db_instance" "dbinstance" {
    allocated_storage          = 5
    max_allocated_storage      = 10
    storage_type               = "gp2"
    engine                     = "mysql"
    engine_version             = "5.7"
    instance_class             = "db.t2.micro"
    db_name                    = "mydb"
    username                   = "admin"
    password                   = "test1234"
    parameter_group_name       = "default.mysql5.7"
    skip_final_snapshot        = true
    auto_minor_version_upgrade = true
    vpc_security_group_ids     = [aws_security_group.database_sg.id]
    db_subnet_group_name       = "${aws_db_subnet_group.rds_public.name}"
    publicly_accessible        = true
    port                       = 3306
#    depends_on = [module.vpc.vpc_id]
}

#===== IAM roles & policies =====
resource "aws_iam_role" "IAM_role" {
    name = "eks-cluster"
    assume_role_policy = jsonencode ({
        Version = "2012-10-17"
        Statement = [{
            Action = "sts:AssumeRole"
            Effect = "Allow"
            Principal = {
                Service = ["ec2.amazonaws.com", "eks.amazonaws.com"]
#                Service = "eks.amazonaws.com"
#                Service = "eks-fargate-pods.amazonaws.com"
            }
        }]
    })
}


resource "aws_iam_role_policy_attachment" "Cluster-Policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.IAM_role.name
}

resource "aws_iam_role_policy_attachment" "WorkerNodePolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.IAM_role.name
}

resource "aws_iam_role_policy_attachment" "EKS_CNI_Policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.IAM_role.name
}

resource "aws_iam_role_policy_attachment" "EC2ContainerRegistryReadOnly" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.IAM_role.name
}

resource "aws_iam_role_policy_attachment" "example-AmazonEKSFargatePodExecutionRolePolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSFargatePodExecutionRolePolicy"
  role       = aws_iam_role.IAM_role.name
}

#===== EKS cluster =====

resource "aws_eks_cluster" "eks_cluster" {
  name = local.cluster_name
  role_arn = aws_iam_role.IAM_role.arn
  vpc_config {
    subnet_ids = module.vpc.public_subnets
    security_group_ids = [aws_security_group.wordpress_sg.id]
  }
  depends_on = [aws_iam_role_policy_attachment.Cluster-Policy]
  tags = {
    Name = "eks_cluster"
  }  
}

resource "aws_eks_node_group" "eks_ng" {
    cluster_name    = aws_eks_cluster.eks_cluster.name
    node_group_name = "task6"
    node_role_arn   = aws_iam_role.IAM_role.arn
    subnet_ids      = module.vpc.public_subnets
    instance_types  = ["t2.small"]
    scaling_config  {
        desired_size = 1
        min_size     = 1
        max_size     = 1
    }
    depends_on = [aws_iam_role_policy_attachment.WorkerNodePolicy, aws_iam_role_policy_attachment.EKS_CNI_Policy, aws_iam_role_policy_attachment.EC2ContainerRegistryReadOnly]
}

data "aws_eks_cluster" "eks_cluster" {
  name = aws_eks_cluster.eks_cluster.name
}

data "aws_eks_cluster_auth" "eks_auth" {
    name = aws_eks_cluster.eks_cluster.name
}

#==== Kubernetes deploy =====
resource "kubernetes_deployment" "wordpress" {
  metadata {
    name = "wordpress"
    labels = {
      App = "wordpress"
    }
  }

  spec {
    replicas = 2
    progress_deadline_seconds = 1800
    selector {
      match_labels = {
        App  = "wordpress"
        tier = "frontend"
      }
    }
    strategy {
        type = "Recreate"
    }    
    template {
      metadata {
        labels = {
          App = "wordpress"
          tier = "frontend"
        }
      }
      spec {
        container {
          image = "wordpress:5.6.0-php7.4-apache"
#          image = "wordpress:4.8-apache"
          name  = "wordpress"
		      env{
            name = "WORDPRESS_DB_HOST"
            value = aws_db_instance.dbinstance.address
          }
          env {
            name = "WORDPRESS_DB_NAME"
            value = aws_db_instance.dbinstance.name
          }
          env{
            name = "WORDPRESS_DB_USER"
            value = aws_db_instance.dbinstance.username
          }
          env{
            name = "WORDPRESS_DB_PASSWORD"
             value = aws_db_instance.dbinstance.password
          }
          port {
            container_port = 80
            name = "wordpress"
          }
        }
      }
    }
  }
  depends_on = [aws_eks_node_group.eks_ng]
  timeouts {
    create = "30m"
  }
}


resource "kubernetes_service" "wordpress" {
  metadata {
    name = "wordpress"
#    labels = {
#        App = "wordpress"
#    }
  }
  spec {
    selector = {
      App = kubernetes_deployment.wordpress.spec.0.template.0.metadata[0].labels.App
    }
    port {
      port        = 80
      target_port = 30007
    }

    type = "LoadBalancer"
  }
  depends_on = [aws_eks_node_group.eks_ng]
  
}


#output "lb_ip" {
#  value = kubernetes_service.wordpress.status[0].load_balancer[0].ingress[0].hostname
#}

