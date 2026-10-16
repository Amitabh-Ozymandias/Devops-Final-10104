output "region" {
  value = var.aws_region
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "public_subnet_ids" {
  value = module.vpc.public_subnets
}

output "cluster_name" {
  value = var.create_eks ? module.eks[0].cluster_name : null
}

output "cluster_endpoint" {
  value = var.create_eks ? module.eks[0].cluster_endpoint : null
}

output "configure_kubectl" {
  description = "Run this to point kubectl at the new cluster"
  value       = var.create_eks ? "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks[0].cluster_name}" : "EKS not created (create_eks = false)"
}
