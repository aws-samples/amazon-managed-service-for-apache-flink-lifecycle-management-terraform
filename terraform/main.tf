# Get account id
data "aws_caller_identity" "current" {}

# Get region
data "aws_region" "current" {}

data "aws_iam_policy_document" "flink_app_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["kinesisanalytics.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "flink_app" {
  statement {
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:*Object",
      "s3:ListBucket"
    ]
    resources = [
      "arn:aws:s3:::${var.s3_bucket_name}",
      "arn:aws:s3:::${var.s3_bucket_name}/*"
    ]
  }
  statement {
    actions = [
      "kinesis:DescribeStream*",
      "kinesis:PutRecord*",
      "kinesis:ListShards"
    ]
    resources = [
      "arn:aws:kinesis:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:stream/${var.output_stream_name}"
    ]
  }
  statement {
    actions = [
      "logs:DescribeLogGroups",
      "logs:ListCloudwatchLogStreams",
      "logs:PutLogEvents"
    ]
    resources = [
      aws_cloudwatch_log_group.flink_app.arn,
      aws_cloudwatch_log_stream.flink_app.arn
    ]
  }
}

data "aws_iam_policy_document" "kms_key_policy" {
  version = "2012-10-17"
  policy_id = "key-default-1"

  statement {
    sid    = "Enable IAM User Permissions"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
    actions   = ["kms:*"]
    resources = ["*"]
  }

  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["logs.${data.aws_region.current.name}.amazonaws.com"]
    }
    actions = [
      "kms:Encrypt*",
      "kms:Decrypt*",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:Describe*"
    ]
    resources = ["*"]
    condition {
      test     = "ArnEquals"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values   = ["arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:${var.flink_app_name}"]
    }
  }
}

resource "aws_iam_role" "flink_app" {
  name               = var.flink_app_name
  assume_role_policy = data.aws_iam_policy_document.flink_app_assume_role.json
}

resource "aws_iam_role_policy" "flink_app" {
  name   = "${var.flink_app_name}-policy"
  role   = aws_iam_role.flink_app.id
  policy = data.aws_iam_policy_document.flink_app.json
}

resource "aws_kms_key" "cloudwatch_log_group_key" {
  description             = "KMS key for CloudWatch Log Group encryption"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.kms_key_policy.json
}

resource "aws_cloudwatch_log_group" "flink_app" {
  name              = var.flink_app_name
  retention_in_days = var.cloudwatch_log_retention
  kms_key_id        = aws_kms_key.cloudwatch_log_group_key.arn
}

resource "aws_cloudwatch_log_stream" "flink_app" {
  name           = var.flink_app_name
  log_group_name = aws_cloudwatch_log_group.flink_app.name
}

resource "aws_kinesisanalyticsv2_application" "flink_app" {
  name                   = var.flink_app_name
  runtime_environment    = var.flink_app_runtime_environment
  service_execution_role = aws_iam_role.flink_app.arn
  start_application      = var.flink_app_start
  force_stop             = true

  cloudwatch_logging_options {
    log_stream_arn = aws_cloudwatch_log_stream.flink_app.arn
  }

  application_configuration {

    run_configuration {
        application_restore_configuration {
            application_restore_type = var.flink_app_restore_type
            snapshot_name = var.flink_app_snapshot_name
        }
        
        flink_run_configuration {
            allow_non_restored_state = var.flink_app_allow_non_restored_state
        }
    }

    flink_application_configuration {

      checkpoint_configuration {
        configuration_type = "DEFAULT"
      }

      monitoring_configuration {
        configuration_type = "CUSTOM"
        log_level          = var.flink_app_monitoring_log_level
        metrics_level      = var.flink_app_monitoring_metrics_level
      }

      parallelism_configuration {
        auto_scaling_enabled = var.flink_app_autoscaling_enabled
        configuration_type   = "CUSTOM"
        parallelism          = var.flink_app_parallelism
        parallelism_per_kpu  = var.flink_app_parallelism_per_kpu
      }
    }

    environment_properties {
      dynamic property_group {
        for_each = var.flink_app_environment_variables
        content {
          property_group_id = property_group.key
          property_map      = property_group.value
        }
      }
    }

    application_snapshot_configuration {
      snapshots_enabled = var.flink_app_snapshots_enabled
    }

    application_code_configuration {
      code_content {
        s3_content_location {
          bucket_arn = "arn:aws:s3:::${var.s3_bucket_name}"
          file_key   = var.s3_file_key
        }
      }
      code_content_type = var.code_content_type
    }
  }
}
