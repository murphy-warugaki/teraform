resource "aws_launch_configuration" "ivy" {
  name_prefix = "ivy"
  image_id = "ami-04b2d1589ab1d972c" # ami
  instance_type = "t2.micro"

  security_groups = ["${aws_security_group.instance.id}"]

  user_data = file("./apache.sh")

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "instance" {
    name = "terraform-example-instance"
    ingress {
        from_port   = 80
        to_port     = 80
        protocol    = "tcp"
        cidr_blocks = ["0.0.0.0/0"]
    }

    egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # 追加
  lifecycle {
      create_before_destroy = true
  }
}

data "aws_availability_zones" "all" {}

resource "aws_autoscaling_group" "example" {
  launch_configuration = "${aws_launch_configuration.ivy.id}"
  availability_zones = data.aws_availability_zones.all.names

  load_balancers = ["${aws_elb.example.name}"]
  health_check_type = "ELB"

  min_size = 1
  max_size = 5

  tag {
      key = "Name"
      value = "terraform autoscaling ver_6"
      propagate_at_launch = true
  }
}

resource "aws_security_group" "elb" {
    name = "terraform-example-elb"

    ingress {
        from_port   = 80
        to_port     = 80
        protocol    = "tcp"
        cidr_blocks = ["0.0.0.0/0"]
    }

    egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_elb" "example" {
    name = "terraform-asg-example"
    availability_zones = data.aws_availability_zones.all.names
    security_groups = [aws_security_group.elb.id]

    listener {
        lb_port = 80
        lb_protocol = "http"
        instance_port = 80
        instance_protocol = "http"
    }

    # 追加
    health_check {
        healthy_threshold = 2
        unhealthy_threshold = 2
        timeout = 3
        interval = 30
        target = "HTTP:80/"
    }
}

### new

resource "aws_lb" "test-ivy" {
  name                       = "test-ivy"

  # ALB or NLB (network)
  load_balancer_type         = "application"

  # for internet or only vpc
  # this time development is false , because internet
  internal                   = false

  # second
  idle_timeout               = 60

  # protect for production
  # 削除するときは一度falseにしてapply
  enable_deletion_protection = true

  subnets = [
    aws_subnet.az1.id,
    aws_subnet.az2.id,
    aws_subnet.az3.id,
  ]

/*
ログ保持するか確認
  access_logs {
    bucket  = aws_s3_bucket.alb_log.id
    enabled = true
  }
*/

  security_groups = [
    module.http_sg.security_group_id,
    module.https_sg.security_group_id,
    module.http_redirect_sg.security_group_id,
  ]
}

output "alb_dns_name" {
  value = aws_lb.test-ivy.dns_name
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.test-ivy.arn
  port              = "80"
  protocol          = "HTTP"

/*
  forward - リクエストを別のターゲットグループに転送
  fixed-response - 固定のHTTPレスポンスを応答
  redirect - 別のURLにリダイレクト”
*/
  default_action {
    type = "fixed-response"

    fixed_response {
      content_type = "text/plain"
      message_body = "これは『HTTP』です"
      status_code  = "200"
    }
  }
}

data "aws_route53_zone" "test-ivy" {
  name = "test-ivy.hassyadai.com"
}

resource "aws_route53_record" "test-ivy" {
  zone_id = data.aws_route53_zone.test-ivy.zone_id
  name    = data.aws_route53_zone.test-ivy.name

  # ALIASレコード
  type    = "A"

  alias {
    name                   = aws_lb.test-ivy.dns_name
    zone_id                = aws_lb.test-ivy.zone_id
    evaluate_target_health = true
  }
}

# ssl証明関係
resource "aws_acm_certificate" "test-ivy" {
  domain_name               = data.aws_route53_zone.test-ivy.name

  # ドメイン名を追加したい場合
  subject_alternative_names = []

  # ドメインの所有権の検証方法 email or dns
  validation_method         = "DNS"

  # リソースを作成してから、リソースを削除する
  lifecycle {
    create_before_destroy = false
  }
}

resource "aws_route53_record" "test-ivy_certificate" {
  name    = aws_acm_certificate.test-ivy.domain_validation_options[0].resource_record_name
  type    = aws_acm_certificate.test-ivy.domain_validation_options[0].resource_record_type
  records = [aws_acm_certificate.test-ivy.domain_validation_options[0].resource_record_value]
  zone_id = data.aws_route53_zone.test-ivy.id
  ttl     = 60
}

# apply時にSSL証明書の検証が完了するまで待ってくれる
/*
resource "aws_acm_certificate_validation" "test-ivy" {
  certificate_arn         = aws_acm_certificate.test-ivy.arn
  validation_record_fqdns = [aws_route53_record.test-ivy_certificate.fqdn]
}
*/

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.test-ivy.arn
  port              = "443"
  protocol          = "HTTPS"
  certificate_arn   = aws_acm_certificate.test-ivy.arn
  ssl_policy        = "ELBSecurityPolicy-2016-08"

/*
  forward - リクエストを別のターゲットグループに転送
  fixed-response - 固定のHTTPレスポンスを応答
  redirect - 別のURLにリダイレクト”
*/
  default_action {
    type = "fixed-response"

    fixed_response {
      content_type = "text/plain"
      message_body = "これは『HTTPSSSS』です"
      status_code  = "200"
    }
  }
}

resource "aws_lb_listener" "redirect_http_to_https" {
  load_balancer_arn = aws_lb.test-ivy.arn
  port              = "8080"
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

resource "aws_lb_target_group" "test-ivy" {
  name                 = "test-ivy"
  vpc_id               = aws_vpc.test-ivy.id

  # EC2インスタンスやIPアドレス、Lambda関数などが指定できる
  target_type          = "ip"

  port                 = 80
  protocol             = "HTTP"

  # ターゲットを登録解除する前にALBが待機する時間
  deregistration_delay = 300

  health_check {
    # ヘルスチェックで使用するパス
    path                = "/"
    # 正常判定を行うまでのヘルスチェック実行回数
    healthy_threshold   = 5
    # 異常判定を行うまでのヘルスチェック実行回数
    unhealthy_threshold = 2
    # ヘルスチェックのタイムアウト時間（秒）
    timeout             = 5
    # ヘルスチェックの実行間隔（秒）
    interval            = 30
    # 正常判定を行うために使用するHTTPステータスコード
    matcher             = 200
    # traffic-portを使うと上で定義したポートが利用される
    port                = "traffic-port"
    protocol            = "HTTP"
  }

  # ALBとターゲットグループを同時に作成するとエラーになるので依存関係を持たせる
  depends_on = [aws_lb.test-ivy]
}

# ターゲットグループにリクエストをフォワードするルール
# 複数定義可能
resource "aws_lb_listener_rule" "test-ivy" {
  listener_arn = aws_lb_listener.https.arn
  # 優先順位
  priority     = 100

  # ターゲットグループ指定
  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.test-ivy.arn
  }

  # path or host
  condition {
    path_pattern {
      # 全てのパスで一致
      values = ["/*"]
    }
  }
}
