data "aws_caller_identity" "current" {}

locals {
  eks_cluster = {
    min_size                 = 3
    max_size                 = 4
    desired_size             = 3
    name                     = "eks-self-managed-ayush-1"
    environment_name         = "dev"
    version                  = "1.24"
    is_mixed_instance_policy = true
    vpc_id                   = "vpc-0cdbbbd4cedcea769"
    vpc_cidr                 = ["172.31.0.0/16"]
    subnet_ids               = ["subnet-0257e8262a7017948", "subnet-062a9cb5ea10455da", "subnet-06b6a7e3c22de35ca"]
    instance_type            = "t3a.medium"
    instances_distribution = {
      on_demand_base_capacity                  = 0
      on_demand_percentage_above_base_capacity = 20
      spot_allocation_strategy                 = "capacity-optimized"
    }
    override = [
      {
        instance_type     = "t3a.large"
        weighted_capacity = "1"
      },
      {
        instance_type     = "t3.large"
        weighted_capacity = "2"
      },
    ]
    block_device_mappings = {
      xvda = {
        device_name = "/dev/xvda"
        ebs = {
          volume_size           = 50
          volume_type           = "gp3"
          iops                  = 3000
          throughput            = 150
          encrypted             = true
          delete_on_termination = true
        }
      }
    }
    cluster_security_group = {
      cluster_rule_ingress = {
        description = "cluster SG"
        protocol    = "tcp"
        from_port   = 0
        to_port     = 65535
        type        = "ingress"
        cidr_blocks = ["0.0.0.0/0"]
      },
      cluster_rule_egress = {
        description = "cluster SG"
        protocol    = "tcp"
        from_port   = 0
        to_port     = 65535
        type        = "egress"
        cidr_blocks = ["0.0.0.0/0"]
      }
    }
    node_security_group = {
      node_rules_ingress = {
        description = "node SG"
        protocol    = "TCP"
        from_port   = 0
        to_port     = 65535
        type        = "ingress"
        cidr_blocks = ["0.0.0.0/0"]
      }
      node_rules_egress = {
        description = "node SG"
        protocol    = "tcp"
        from_port   = 0
        to_port     = 65535
        type        = "egress"
        cidr_blocks = ["0.0.0.0/0"]
      }
    }
    #aws eks describe-addon-version
    addons = {
      vpc-cni = {
        resolve_conflicts = "OVERWRITE"
      },
      # aws-ebs-csi-driver = {
      #   resolve_conflicts = "OVERWRITE"
      # },
      kube-proxy = {
        resolve_conflicts = "OVERWRITE"
      }
    }
    lb = {
      image = {
        repository = "public.ecr.aws/eks/aws-load-balancer-controller"
        tag        = "v2.4.6"
      }
    }
  }
}

provider "kubernetes" {
  host                   = module.eks_cluster.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks_cluster.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", local.eks_cluster.name]
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks_cluster.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks_cluster.cluster_certificate_authority_data)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", local.eks_cluster.name]
    }
  }
}

# provider "kubectl" {
#   kubernetes {
#     host                   = module.eks_cluster.cluster_endpoint
#     cluster_ca_certificate = base64decode(module.eks_cluster.cluster_certificate_authority_data)
#     exec {
#       api_version = "client.authentication.k8s.io/v1beta1"
#       command     = "aws"
#       args = ["eks", "get-token", "--cluster-name", local.eks_cluster.name]
#     }
#   }
# }

module "eks_cluster" {
  source          = "git::https://github.com/tothenew/terraform-aws-eks.git"
  cluster_name    = local.eks_cluster.name
  cluster_version = try(local.eks_cluster.version, "1.24")

  cluster_endpoint_private_access = try(local.eks_cluster.cluster_endpoint_private_access, false)
  cluster_endpoint_public_access  = try(local.eks_cluster.cluster_endpoint_public_access, true)

  vpc_id     = local.eks_cluster.vpc_id
  subnet_ids = local.eks_cluster.subnet_ids

  # Self managed node groups will not automatically create the aws-auth configmap so we need to
  create_aws_auth_configmap = true
  manage_aws_auth_configmap = true
  create                    = true

  #Cluster Level Addons
  # cluster_addons = local.eks_cluster.addons

  self_managed_node_group_defaults = {
    instance_type                          = "${local.eks_cluster.instance_type}"
    update_launch_template_default_version = true
    iam_role_additional_policies = [
      "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
    ]
  }
  # cluster_security_group_additional_rules = local.eks_cluster.cluster_security_group
  self_managed_node_groups = {
    # Default node group - as provisioned by the module defaults
    # default_node_group = {
    #   name = local.eks_cluster.name
    # }
    mixed = {
      name         = local.eks_cluster.name
      min_size     = try(local.eks_cluster.min_size, 2)
      max_size     = try(local.eks_cluster.max_size, 4)
      desired_size = try(local.eks_cluster.min_size, 2)
      tags = {
        "k8s.io/cluster-autoscaler/enabled"                   = "true"
        "k8s.io/cluster-autoscaler/${local.eks_cluster.name}" = "owned"
      }
      create_security_group          = true
      security_group_name            = local.eks_cluster.name
      security_group_use_name_prefix = true
      security_group_description     = "Self managed NodeGroup SG"
      security_group_rules           = local.eks_cluster.node_security_group

      # pre_bootstrap_user_data = <<-EOT
      #   TOKEN=`curl -s  -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600"`
      #   EC2_LIFE_CYCLE=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN"  http://169.254.169.254/latest/meta-data/instance-life-cycle)
      #   INSTANCE_TYPE=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN"  http://169.254.169.254/latest/meta-data/instance-type)
      #   AVAILABILITY_ZONE=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN"  http://169.254.169.254/latest/meta-data/placement/availability-zone)
      #   EOT

      # bootstrap_extra_args = "--kubelet-extra-args '--node-labels=node.kubernetes.io/lifecycle='\"$EC2_LIFE_CYCLE\"' --register-with-taints=instance_type='\"$INSTANCE_TYPE\"':NoSchedule,ec2_lifecycle='\"$EC2_LIFE_CYCLE\"':NoSchedule,availability_zone='\"$AVAILABILITY_ZONE\"':NoSchedule'"


      post_bootstrap_user_data = <<-EOT
        cd /tmp
        sudo yum install -y https://s3.amazonaws.com/ec2-downloads-windows/SSMAgent/latest/linux_amd64/amazon-ssm-agent.rpm
        sudo systemctl enable amazon-ssm-agent
        sudo systemctl start amazon-ssm-agent
        EOT

      block_device_mappings      = "${local.eks_cluster.block_device_mappings}"
      use_mixed_instances_policy = "${local.eks_cluster.is_mixed_instance_policy}"
      mixed_instances_policy = {
        instances_distribution = "${local.eks_cluster.instances_distribution}"
        override               = "${local.eks_cluster.override}"
      }
    }
  }
}

module "load_balancer_controller" {
  source = "git::https://github.com/tothenew/terraform-aws-eks.git//modules/terraform-aws-eks-lb-controller"

  cluster_identity_oidc_issuer     = module.eks_cluster.cluster_oidc_issuer_url
  cluster_identity_oidc_issuer_arn = module.eks_cluster.oidc_provider_arn
  cluster_name                     = module.eks_cluster.cluster_id
  depends_on = [
    module.eks_cluster
  ]
  settings = local.eks_cluster.lb
}


resource "helm_release" "ingress" {
  name      = "helm-ing"
  namespace = "default"
  chart     = "./helm/alb-ingress"
  version   = "6.0.1"

  values = [
    "${file("./helm/alb-ingress/values.yaml")}"
  ]
}

resource "kubernetes_config_map" "kong-config" {
  metadata {
    name = "kong-config"
  }
  depends_on = [
    module.create_database
  ]

  data = {
    "nginx_kong.lua" = "${file("./helm/configmap.yml")}"
  }
}

resource "helm_release" "kong" {
  depends_on = [
    resource.kubernetes_pod.kong_migration
  ]
  name    = "kong"
  timeout = 180
  # namespace   = "default"
  chart = "./helm/kong"
  set {
    name  = "deployment.containers[0].env[1].name"
    value = "KONG_PG_HOST"
  }
  set {
    name  = "deployment.containers[0].env[1].value"
    value = module.create_database.endpoint
  }
  set {
    name  = "deployment.containers[0].env[2].name"
    value = "KONG_PG_USER"
  }
  set {
    name  = "deployment.containers[0].env[2].value"
    value = module.create_database.username
  }
  set {
    name  = "deployment.containers[0].env[3].name"
    value = "KONG_PG_PASSWORD"
  }
  set {
    name  = "deployment.containers[0].env[3].value"
    value = module.create_database.password
  }
  values = [
    "${file("./helm/kong-values.yaml")}"
  ]
}

resource "helm_release" "konga" {
  depends_on = [
    helm_release.kong
  ]
  name = "konga"
  # namespace   = "default"
  chart   = "./helm/konga"
  timeout = 180
  set {
    name  = "deployment.containers[0].env[1].name"
    value = "DB_HOST"
  }
  set {
    name  = "deployment.containers[0].env[1].value"
    value = module.create_database.endpoint
  }
  set {
    name  = "deployment.containers[0].env[3].name"
    value = "DB_PASSWORD"
  }
  set {
    name  = "deployment.containers[0].env[3].value"
    value = module.create_database.password
  }
  set {
    name  = "deployment.containers[0].env[2].name"
    value = "DB_USER"
  }
  set {
    name  = "deployment.containers[0].env[2].value"
    value = module.create_database.username
  }
  values = [
    "${file("./helm/konga-values.yaml")}"
  ]
}

# psql -h kong-database-0.c8m4uwvxecdh.ap-south-1.rds.amazonaws.com -U root postgres 
# b9909FTArBOsPoOlYERWC8QMex9KrIEXll

# k run kong --image=saifahmadttn/kong:2.7.0 --env=KONG_PG_USER=root --env=KONG_PG_DATABASE=kong_db --env=KONG_DATABASE=postgres --env=KONG_PG_PASSWORD=b9909FTArBOsPoOlYERWC8QMex9KrIEXll --env=KONG_PG_HOST=kong-database-0.c8m4uwvxecdh.ap-south-1.rds.amazonaws.com --command -- kong migrations bootstrap

module "create_database" {
  source = "git::https://github.com/ayushme001/terraform-aws-rds.git"

  create_rds    = false
  create_aurora = true

  subnet_ids = local.eks_cluster.subnet_ids
  vpc_id     = local.eks_cluster.vpc_id
  vpc_cidr   = local.eks_cluster.vpc_cidr

  publicly_accessible                    = true
  allocated_storage                      = 10
  max_allocated_storage                  = 20
  engine                                 = "aurora-postgresql"
  engine_version                         = "11.18"
  instance_class                         = "db.t3.medium"
  database_name                          = "postgres"
  username                               = "root"
  identifier                             = "kong-database"
  apply_immediately                      = false
  port                                   = 5432
  storage_encrypted                      = false
  multi_az                               = false
  db_subnet_group_id                     = "kong-rds"
  deletion_protection                    = false
  auto_minor_version_upgrade             = false
  count_aurora_instances                 = 1
  serverlessv2_scaling_configuration_max = 1.0
  serverlessv2_scaling_configuration_min = 0.5
  common_tags = {
    "Project"     = "Kong",
    "Environment" = "dev"
  }
  environment = "dev"
}

# terraform {
#   required_version = ">= 1.3.0"
#   required_providers {
#     postgresql = { # This line is what needs to change.
#       source = "cyrilgdn/postgresql"
#       version = "1.15.0"
#     }
#   }
# }

provider "postgresql" {
  host            = module.create_database.endpoint
  port            = module.create_database.port
  database        = "postgres"
  username        = module.create_database.username
  password        = module.create_database.password
  connect_timeout = 15
}

resource "postgresql_database" "kong" {
  depends_on = [
    module.create_database
  ]
  name = "kong_db"
}

resource "postgresql_database" "konga" {
  depends_on = [
    module.create_database
  ]
  name = "konga_db"
}

resource "kubernetes_pod" "kong_migration" {
  depends_on = [
    postgresql_database.kong
  ]
  metadata {
    name = "kong-migration"
  }

  spec {
    container {
      image = "saifahmadttn/kong:2.7.0"
      name  = "kong-migration"

      env {
        name  = "KONG_DATABASE"
        value = "postgres"
      }
      env {
        name  = "KONG_PG_HOST"
        value = module.create_database.endpoint
      }
      env {
        name  = "KONG_PG_USER"
        value = module.create_database.username
      }
      env {
        name  = "KONG_PG_PASSWORD"
        value = module.create_database.password
      }
      env {
        name  = "KONG_ADMIN_LISTEN"
        value = "0.0.0.0:8001"
      }
      env {
        name  = "KONG_ADMIN_LISTEN_SSL"
        value = "0.0.0.0:8444"
      }
      env {
        name  = "KONG_TRUSTED_IPS"
        value = "0.0.0.0/0,::/0"
      }
      env {
        name  = "KONG_PG_DATABASE"
        value = "kong_db"
      }
      command = ["kong", "migrations", "bootstrap"]
      port {
        container_port = 8001
      }
    }
    # dns_policy = "None"
  }
}