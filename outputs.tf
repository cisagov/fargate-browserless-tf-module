output "lb_dns_name" {
  value = "${aws_lb.network.dns_name}:${var.lb_port}"
}

output "container_name" {
  value = module.label.id
}
