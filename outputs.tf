output "public_subnet" {
    value = module.vpc.public_subnets
}

output "lb_ip2" {
#   value = kubernetes_service.wordpress.spec.0.port.0.node_port
  value = kubernetes_service.wordpress.status[0].load_balancer[0].ingress[0].hostname
}

#output "lb_tg" {
#    value =  aws_lb_target_group.target_group.arn
#}
#output "lb_listener" {
#    value = aws_lb_listener.listener.id
#}

output "vpc_id" {
    value = module.vpc.vpc_id
}
#output "alb_listener" {
#    value = aws_lb_listener.listener
#}


  