output "alb_dns" {
  value = aws_lb.alb.dns_name
}
output "rds_endpoint" {
  value     = aws_db_instance.this.address
  sensitive = true
}
