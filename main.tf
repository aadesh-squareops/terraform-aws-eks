module "eks_addon" {
  count                     = var.default_addon_enabled ? 1 : 0
  source                    = "terraform-aws-modules/eks/aws"
  version                   = "19.15.2"
  vpc_id                    = var.vpc_id
  subnet_ids                = var.private_subnet_ids
  enable_irsa               = true
  cluster_name              = format("%s-%s", var.environment, var.name)
  create_kms_key            = var.create_kms_key
  cluster_version           = var.cluster_version
  cluster_enabled_log_types = var.cluster_log_types
  tags = {
    "Name"        = format("%s-%s", var.environment, var.name)
    "Environment" = var.environment
  }
  aws_auth_roles                          = var.aws_auth_roles
  aws_auth_users                          = var.aws_auth_users
  create_aws_auth_configmap               = var.create_aws_auth_configmap
  manage_aws_auth_configmap               = var.create_aws_auth_configmap
  cluster_security_group_additional_rules = var.additional_rules
  cluster_endpoint_public_access          = var.cluster_endpoint_public_access
  cluster_endpoint_private_access         = var.cluster_endpoint_public_access ? false : true
  cluster_endpoint_public_access_cidrs    = var.cluster_endpoint_public_access_cidrs
  cloudwatch_log_group_retention_in_days  = var.cluster_log_retention_in_days
  cloudwatch_log_group_kms_key_id         = var.kms_key_arn
  cluster_encryption_config = {
    provider_key_arn = var.kms_key_arn
    resources        = ["secrets"]
  }
  cluster_ip_family = var.ipv6_enabled ? "ipv6" : null
  cluster_addons = {
    coredns = {
      preserve    = true
      most_recent = true

      timeouts = {
        create = "25m"
        delete = "10m"
      }
    }
    kube-proxy = {
      most_recent = true
    }
    vpc-cni = {
      most_recent = true
    }
    aws-ebs-csi-driver = {
      most_recent = true
    }
  }
}

module "eks" {
  count                     = var.default_addon_enabled ? 0 : 1
  source                    = "terraform-aws-modules/eks/aws"
  version                   = "19.15.2"
  vpc_id                    = var.vpc_id
  subnet_ids                = var.private_subnet_ids
  enable_irsa               = true
  cluster_name              = format("%s-%s", var.environment, var.name)
  create_kms_key            = var.create_kms_key
  cluster_version           = var.cluster_version
  cluster_enabled_log_types = var.cluster_log_types
  tags = {
    "Name"        = format("%s-%s", var.environment, var.name)
    "Environment" = var.environment
  }
  aws_auth_roles                          = var.aws_auth_roles
  aws_auth_users                          = var.aws_auth_users
  create_aws_auth_configmap               = var.create_aws_auth_configmap
  manage_aws_auth_configmap               = var.create_aws_auth_configmap
  cluster_security_group_additional_rules = var.additional_rules
  cluster_endpoint_public_access          = var.cluster_endpoint_public_access
  cluster_endpoint_private_access         = var.cluster_endpoint_public_access ? false : true
  cluster_endpoint_public_access_cidrs    = var.cluster_endpoint_public_access_cidrs
  cloudwatch_log_group_retention_in_days  = var.cluster_log_retention_in_days
  cloudwatch_log_group_kms_key_id         = var.kms_key_arn
  cluster_encryption_config = {
    provider_key_arn = var.kms_key_arn
    resources        = ["secrets"]
  }
  cluster_ip_family = var.ipv6_enabled ? "ipv6" : null
}

resource "aws_iam_policy" "kubernetes_pvc_kms_policy" {
  name        = format("%s-%s-%s", var.environment, var.name, "kubernetes-pvc-kms-policy")
  description = "Allow kubernetes pvc to get access of KMS."
  policy      = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
      {
        "Effect": "Allow",
        "Action": [
            "kms:Decrypt",
            "kms:CreateGrant",
            "kms:GenerateDataKeyWithoutPlaintext"
        ],
        "Resource": "${var.kms_key_arn}"
      }
  ]
}
EOF
}

resource "aws_iam_role_policy_attachment" "eks_kms_cluster_policy_attachment" {
  role       = var.default_addon_enabled ? module.eks_addon[0].cluster_iam_role_name : module.eks[0].cluster_iam_role_name
  policy_arn = aws_iam_policy.kubernetes_pvc_kms_policy.arn
}

resource "aws_iam_role" "node_role" {
  name               = format("%s-%s-node-role", var.environment, var.name)
  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
EOF
  tags = merge(
    { "Name"        = format("%s-%s-node-role", var.environment, var.name)
      "Environment" = var.environment
    }
  )
}
data "aws_ami" "launch_template_ami" {
  count       = var.default_addon_enabled ? 1 : 0
  owners      = ["602401143452"]
  most_recent = true
  filter {
    name   = "name"
    values = [format("%s-%s-%s", "amazon-eks-node", module.eks_addon[0].cluster_version, "v*")]
  }
}

data "aws_iam_policy" "SSMManagedInstanceCore" {
  arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "SSMManagedInstanceCore_attachment" {
  role       = aws_iam_role.node_role.name
  policy_arn = data.aws_iam_policy.SSMManagedInstanceCore.arn
}

resource "aws_iam_policy" "node_autoscaler_policy" {
  name        = format("%s-%s-node-autoscaler-policy", var.environment, var.name)
  path        = "/"
  description = "Node auto scaler policy for node groups."
  policy      = <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
              "autoscaling:DescribeTags",
              "autoscaling:SetDesiredCapacity",
              "ec2:DescribeLaunchTemplateVersions",
                "autoscaling:DescribeAutoScalingGroups",
                "autoscaling:DescribeAutoScalingInstances",
                "autoscaling:DescribeLaunchConfigurations",
                "autoscaling:TerminateInstanceInAutoScalingGroup"

            ],
            "Resource": "*"
        }
    ]
}
EOF
}

resource "aws_iam_role_policy_attachment" "node_autoscaler_policy" {
  role       = aws_iam_role.node_role.name
  policy_arn = aws_iam_policy.node_autoscaler_policy.arn
}

resource "aws_iam_policy" "eks_cni_ipv6_policy" {
  count       = var.ipv6_enabled == true ? 1 : 0
  name        = format("%s-%s-eks-cni-ipv6-policy", var.environment, var.name)
  path        = "/"
  description = "Node cni policy for node groups."
  policy      = <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "ec2:AssignIpv6Addresses",
                "ec2:DescribeInstances",
                "ec2:DescribeTags",
                "ec2:DescribeNetworkInterfaces",
                "ec2:DescribeInstanceTypes"
            ],
            "Resource": "*"
        },
        {
            "Effect": "Allow",
            "Action": [
                "ec2:CreateTags"
            ],
            "Resource": [
                "arn:aws:ec2:*:*:network-interface/*"
            ]
        }
    ]
}
EOF
}

resource "aws_iam_role_policy_attachment" "eks_kms_worker_policy_attachment" {
  role       = aws_iam_role.node_role.name
  policy_arn = var.kms_policy_arn
}

resource "aws_iam_role_policy_attachment" "eks_worker_policy" {
  role       = aws_iam_role.node_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "cni_policy" {
  role       = aws_iam_role.node_role.name
  policy_arn = var.ipv6_enabled == false ? "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy" : aws_iam_policy.eks_cni_ipv6_policy[0].arn
}

resource "aws_iam_role_policy_attachment" "eks_worker_ecr_policy" {
  role       = aws_iam_role.node_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

data "template_file" "launch_template_userdata" {
  count    = var.default_addon_enabled ? 1 : 0
  template = file("${path.module}/modules/managed-nodegroup/templates/${var.ipv6_enabled == false ? "custom-bootstrap-script.sh.tpl" : "custom-bootstrap-scriptipv6.sh.tpl"}")

  vars = {
    endpoint                     = module.eks_addon[0].cluster_endpoint
    cluster_name                 = module.eks_addon[0].cluster_name
    eventRecordQPS               = var.eventRecordQPS
    cluster_auth_base64          = module.eks_addon[0].cluster_certificate_authority_data
    image_low_threshold_percent  = var.image_low_threshold_percent
    image_high_threshold_percent = var.image_high_threshold_percent

  }
}

resource "aws_launch_template" "eks_template" {
  count                  = var.default_addon_enabled ? 1 : 0
  name                   = format("%s-%s-%s", var.environment, var.name, "default-launch-template")
  key_name               = var.eks_nodes_keypair_name
  image_id               = data.aws_ami.launch_template_ami[0].image_id
  user_data              = base64encode(data.template_file.launch_template_userdata[0].rendered)
  update_default_version = true
  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = var.ebs_volume_size
      volume_type           = var.ebs_volume_type
      delete_on_termination = true
      encrypted             = var.ebs_encrypted
      kms_key_id            = var.kms_key_arn
    }
  }

  network_interfaces {
    associate_public_ip_address = var.associate_public_ip_address
    delete_on_termination       = true
  }

  monitoring {
    enabled = var.enable_monitoring
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name        = format("%s-%s-%s", var.environment, var.name, "eks-node")
      Environment = var.environment
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_eks_node_group" "default_ng" {
  count           = var.default_addon_enabled ? 1 : 0
  subnet_ids      = var.subnet_ids
  cluster_name    = module.eks_addon[0].cluster_name
  node_role_arn   = aws_iam_role.node_role.arn
  node_group_name = format("%s-%s-%s", var.environment, "default", "ng")
  scaling_config {
    desired_size = var.desired_size
    max_size     = var.max_size
    min_size     = var.min_size
  }
  labels         = var.k8s_labels
  capacity_type  = var.capacity_type
  instance_types = var.instance_types
  launch_template {
    id      = aws_launch_template.eks_template[0].id
    version = aws_launch_template.eks_template[0].latest_version
  }
  lifecycle {
    create_before_destroy = true
    ignore_changes = [
      scaling_config[0].desired_size,
    ]
  }
  tags = {
    Name        = format("%s-%s-%s", var.environment, "default", "ng")
    Environment = var.environment
  }
}
