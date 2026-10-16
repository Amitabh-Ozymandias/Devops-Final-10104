data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# ---------------------------------------------------------------------------
# Networking: one VPC with a public subnet per AZ.
# Worker nodes run in the public subnets (with public IPs) so no NAT gateway
# is needed - this keeps the course project's AWS bill low.
# ---------------------------------------------------------------------------
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.16"

  name = "${var.project_name}-vpc"
  cidr = var.vpc_cidr
  azs  = local.azs

  public_subnets          = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 8, i)]
  map_public_ip_on_launch = true

  enable_nat_gateway   = false
  enable_dns_hostnames = true
  enable_dns_support   = true

  # Lets the AWS load balancer for the ingress controller find these subnets
  public_subnet_tags = {
    "kubernetes.io/role/elb"                    = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
}

# ---------------------------------------------------------------------------
# EKS cluster with one managed node group
# ---------------------------------------------------------------------------
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.31"

  cluster_name    = var.cluster_name
  cluster_version = var.kubernetes_version

  cluster_endpoint_public_access           = true
  enable_cluster_creator_admin_permissions = true

  # Optional: grant the GitHub Actions IAM identity access to deploy with Helm.
  # Leave empty if CI uses the same IAM identity that runs terraform apply.
  access_entries = {
    for name, entry in {
      ci = {
        principal_arn = var.ci_deployer_arn
        policy_associations = {
          admin = {
            policy_arn   = "arn:aws:eks::aws:policy/AmazonEKSClusterAdminPolicy"
            access_scope = { type = "cluster" }
          }
        }
      }
    } : name => entry if var.ci_deployer_arn != ""
  }

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.public_subnets

  cluster_addons = {
    coredns    = {}
    kube-proxy = {}
    vpc-cni = {
      before_compute = true
    }
  }

  eks_managed_node_groups = {
    default = {
      name           = "${var.project_name}-nodes"
      instance_types = var.node_instance_types
      capacity_type  = "ON_DEMAND"

      min_size     = var.node_min_size
      max_size     = var.node_max_size
      desired_size = var.node_desired_size

      subnet_ids = module.vpc.public_subnets
    }
  }
}
