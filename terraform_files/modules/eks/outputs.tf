# modules/eks/outputs.tf

output "eks_cluster_id" {
  value       = aws_eks_cluster.main.id
  description = "The ID of the EKS cluster"
}

output "eks_cluster_endpoint" {
  value       = aws_eks_cluster.main.endpoint
  description = "The endpoint for the EKS cluster"
}

output "eks_cluster_version" {
  value       = aws_eks_cluster.main.version
  description = "The Kubernetes version for the EKS cluster"
}

output "eks_cluster_name" {
  value       = aws_eks_cluster.main.name
  description = "The name of the EKS cluster"
}