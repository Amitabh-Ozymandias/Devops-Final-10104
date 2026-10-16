variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Name prefix applied to every resource"
  type        = string
  default     = "spendwise"
}

variable "environment" {
  description = "Deployment environment label"
  type        = string
  default     = "dev"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.20.0.0/16"
}

variable "az_count" {
  description = "Number of availability zones (and public subnets) to use"
  type        = number
  default     = 2

  validation {
    condition     = var.az_count >= 2
    error_message = "EKS requires subnets in at least two availability zones."
  }
}

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
  default     = "spendwise-eks"
}

variable "kubernetes_version" {
  description = "EKS Kubernetes version"
  type        = string
  default     = "1.33"
}

variable "node_instance_types" {
  description = "EC2 instance types for the managed node group"
  type        = list(string)
  default     = ["t3.medium"]
}

variable "node_desired_size" {
  description = "Desired number of worker nodes"
  type        = number
  default     = 2
}

variable "node_min_size" {
  description = "Minimum number of worker nodes"
  type        = number
  default     = 1
}

variable "node_max_size" {
  description = "Maximum number of worker nodes"
  type        = number
  default     = 3
}

variable "ci_deployer_arn" {
  description = "IAM user/role ARN used by GitHub Actions to deploy (empty = none)"
  type        = string
  default     = ""
}
