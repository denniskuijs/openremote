#!/bin/bash

# Provisions the standard stack of resources using CloudFormation template (cloudformation-create-ec2.yml) in the
# specified AWS member account; if no account specified then the account of the authenticated user will be used.
# The account must already exist and be provisioned in the standard way (see provision_account.sh).
# Also provisions an SMTP user in the caller account using CloudFormation template (cloudformation-create-smtp-user.yml)
# so this user can be used to send emails from the newly provisioned host (credentials are injected into the host
# environment variables).
# Also provisions a Route 53 Healthcheck alarm using CloudFormation template (cloudformation-healthcheck-alarm.yml) in
# the same AWS member account but in the us-east-1 region (this is the region where Route 53 health checks are
# automatically created).
# To access the account the $AWS_ROLE_NAME role in that account will be assumed (this role must exist and must have
# sufficient privileges to run the commands contained in this script). This script will determine the DNS hosted
# zone into which the A record for the host should be inserted by searching up the domain levels of the hosts FQDN.
# Will also provision an S3 bucket with the name of host (periods replaced with hyphens) unless set to false.
#
# To be called with arguments:
# 1 - AWS_ACCOUNT_NAME where resources should be created (defaults to callers account)
# 2 - HOST FQDN for e.g. staging.demo.openremote.app
# 3 - INSTANCE_TYPE EC2 instance type see cloud formation template parameter
# 4 - ROOT_DISK_SIZE to use for created EBS root volume (GB)
# 5 - DATA_DISK_SIZE to use for created EBS data volume (GB)
# 6 - SNAPSHOT_ID to use for creating the data volume based of an existing snapshot.
# 7 - ELASTIC_IP if 'true' then create an elastic public IP for this host
# 8 - PROVISION_S3_BUCKET set to 'false' to not provision an S3 bucket for this host
# 9 - ENABLE_METRICS set to 'false' to not enable cloudwatch metrics for this instance
# 10 - WAIT_FOR_STACK if 'false' script will not wait until the cloud formation stack is running

if [[ $BASH_SOURCE = */* ]]; then
 awsDir=${BASH_SOURCE%/*}/
else
  awsDir=./
fi

AWS_ACCOUNT_NAME=${1,,}
HOST=${2,,}
INSTANCE_TYPE=${3,,}
ROOT_DISK_SIZE=${4,,}
DATA_DISK_SIZE=${5,,}
SNAPSHOT_ID=${6,,}
ELASTIC_IP=${7,,}
PROVISION_S3_BUCKET=${8,,}
ENABLE_METRICS=${9,,}
WAIT_FOR_STACK=${10,,}

if [ -z "$HOST" ]; then
  echo "Host must be set"
  exit 1
fi

if [ -f "${awsDir}cloudformation-create-ec2.yml" ]; then
  TEMPLATE_PATH="${awsDir}cloudformation-create-ec2.yml"
elif [ -f ".ci_cd/aws/cloudformation-create-ec2.yml" ]; then
  TEMPLATE_PATH=".ci_cd/aws/cloudformation-create-ec2.yml"
elif [ -f "openremote/.ci_cd/aws/cloudformation-create-ec2.yml" ]; then
  TEMPLATE_PATH="openremote/.ci_cd/aws/cloudformation-create-ec2.yml"
else
  echo "Cannot determine location of cloudformation-create-ec2.yml"
  exit 1
fi

# Optionally login if AWS_ENABLED != 'true'
source "${awsDir}login.sh"

ACCOUNT_PROFILE=
# if [ -n "$AWS_ACCOUNT_NAME" ]; then
#   # Update github-da profile with ARN for AWS_ACCOUNT_ID
#   source "${awsDir}set_github-da_account_arn.sh"
#   ACCOUNT_PROFILE="--profile github-da"
# fi

STACK_NAME=$(tr '.' '-' <<< "$HOST")
SMTP_STACK_NAME="$STACK_NAME-smtp"
HEALTH_STACK_NAME="$STACK_NAME-healthcheck"
EBS_STACK_NAME="$STACK_NAME-ebs-data-volume"
DLM_STACK_NAME="$STACK_NAME-dlm-ebs-snapshot-policy"
SSM_STACK_NAME="$STACK_NAME-ssm-attach-detach-documents"

# Provision SMTP user using CloudFormation (if stack doesn't already exist)
echo "Provisioning SMTP user"
STATUS=$(aws cloudformation describe-stacks --stack-name $SMTP_STACK_NAME --query "Stacks[0].StackStatus" --output text 2>/dev/null)

if [ -n "$STATUS" ] && [ "$STATUS" != 'DELETE_COMPLETE' ]; then
  echo "Stack already exists for this host's SMTP user '$HOST' current status is '$STATUS'"
  STACK_ID=$(aws cloudformation describe-stacks --stack-name $SMTP_STACK_NAME --query "Stacks[0].StackId" --output text 2>/dev/null)
else

  if [ -f "${awsDir}cloudformation-create-smtp-user.yml" ]; then
    SMTP_TEMPLATE_PATH="${awsDir}cloudformation-create-smtp-user.yml"
  elif [ -f ".ci_cd/aws/cloudformation-create-smtp-user.yml" ]; then
    SMTP_TEMPLATE_PATH=".ci_cd/aws/cloudformation-create-smtp-user.yml"
  elif [ -f "openremote/.ci_cd/aws/cloudformation-create-smtp-user.yml" ]; then
    SMTP_TEMPLATE_PATH="openremote/.ci_cd/aws/cloudformation-create-smtp-user.yml"
  else
    echo "Cannot determine location of cloudformation-create-smtp-user.yml"
    exit 1
  fi

  #Configure parameters
  PARAMS="ParameterKey=UserName,ParameterValue='$SMTP_STACK_NAME'"

  # Create standard stack resources in specified account
  STACK_ID=$(aws cloudformation create-stack --capabilities CAPABILITY_NAMED_IAM --stack-name $SMTP_STACK_NAME --template-body file://$SMTP_TEMPLATE_PATH --parameters $PARAMS --output text)

  if [ $? -ne 0 ]; then
    echo "Create stack failed"
    exit 1
  fi

  if [ "$WAIT_FOR_STACK" != 'false' ]; then
    # Wait for cloud formation stack status to be CREATE_*
    echo "Waiting for stack to be created"
    STATUS=$(aws cloudformation describe-stacks --stack-name $SMTP_STACK_NAME --query "Stacks[?StackId=='$STACK_ID'].StackStatus" --output text 2>/dev/null)

    while [[ "$STATUS" == 'CREATE_IN_PROGRESS' ]]; do
      echo "Stack creation is still in progress .. Sleeping 30 seconds"
      sleep 30
      STATUS=$(aws cloudformation describe-stacks --stack-name $SMTP_STACK_NAME --query "Stacks[?StackId=='$STACK_ID'].StackStatus" --output text 2>/dev/null)
    done

    if [ "$STATUS" != 'CREATE_COMPLETE' ]; then
      echo "Stack creation has failed status is '$STATUS'"
      exit 1
    else
      echo "Stack creation is complete"
    fi
  fi
fi

# Check stack doesn't already exist
STATUS=$(aws cloudformation describe-stacks --stack-name $STACK_NAME --query "Stacks[0].StackStatus" --output text $ACCOUNT_PROFILE 2>/dev/null)

if [ -n "$STATUS" ] && [ "$STATUS" != 'DELETE_COMPLETE' ]; then
  echo "Stack already exists for this host '$HOST' current status is '$STATUS'"
  STACK_ID=$(aws cloudformation describe-stacks --stack-name $STACK_NAME --query "Stacks[0].StackId" --output text $ACCOUNT_PROFILE 2>/dev/null)
else

  # Get SMTP credentials
  SMTP_HOST="email-smtp.$AWS_REGION.amazonaws.com"
  SMTP_USER=$(aws cloudformation describe-stacks --stack-name $SMTP_STACK_NAME --query "Stacks[0].Outputs[?OutputKey=='SMTPUserKey'].OutputValue" --output text 2>/dev/null)
  SMTP_SECRET=$(aws cloudformation describe-stacks --stack-name $SMTP_STACK_NAME --query "Stacks[0].Outputs[?OutputKey=='SMTPUserSecret'].OutputValue" --output text 2>/dev/null)

  # Determine DNSHostedZoneName and DNSHostedZoneRoleArn (must be set if hosted zone is not in the same account as where the host is being created)
  echo "Determining DNS parameters"
  TLD_NAME=$(awk -F. '{print $(NF-1)"."$(NF)}' <<< "$HOST")
  COUNT=$(($(awk -F. '{print NF}' <<< "$HOST")-1))
  HOSTED_ZONES=$(aws route53 list-hosted-zones --query "HostedZones[?contains(Name, '$TLD_NAME.')].[Name]" --output text $ACCOUNT_PROFILE)

  if [ -n "$ACCOUNT_PROFILE" ]; then
    # Append caller account hosted zones
    read -r -d '' HOSTED_ZONES << EOF
$HOSTED_ZONES
$(aws route53 list-hosted-zones --query "HostedZones[?contains(Name, '$TLD_NAME.')].[Name,'true']" --output text)
EOF
    echo "$HOSTED_ZONES"
  fi

  if [ -n "$HOSTED_ZONES" ]; then
    # Match hosted zone with the same name as the host moving up a domain level each time
    i=1
    while [ $i -le $COUNT ]; do

      HOSTED_ZONE=$(cut -d'.' -f$i- <<< "$HOST")

      IFS=$'\n'
      for zone in $HOSTED_ZONES; do
        IFS=$' \t'
        zoneArr=( $zone )
        name=${zoneArr[0]}
        callerAccount=${zoneArr[1]}

        if [ "$name" == "$HOSTED_ZONE." ]; then
          echo "Found hosted zone for this host '$HOSTED_ZONE'"
          DNSHostedZoneName=$HOSTED_ZONE
          if [ "$callerAccount" == 'true' ]; then
            # Get Role ARN that can be assumed to allow DNS record update for this host from the host's account
            DNSHostedZoneRoleArn=$(aws ssm get-parameter --name Hosted-Zone-Access-Role-Arn --query "Parameter.Value" --output text $ACCOUNT_PROFILE)
            if [ -z "$DNSHostedZoneRoleArn" ]; then
              echo "Failed to get 'Hosted-Zone-Access-Role-Arn' from parameter store this must be set for cross account DNS support"
              exit 1
            fi
          fi
          break
        fi
      done

      if [ -n "$DNSHostedZoneName" ]; then
        break
      fi

      i=$((i+1))
    done
  fi

  # Get OR VPC ID, Subnet ID, SSH Security Group ID and EFS MOUNT TARGET IP
  SUBNET_NUMBER=$(( $RANDOM % 3 + 1 ))
  SUBNETNAME="or-subnet-public-$SUBNET_NUMBER"
  VPCID=$(aws ec2 describe-vpcs --filters Name=tag:Name,Values=or-vpc --query "Vpcs[0].VpcId" --output text $ACCOUNT_PROFILE 2>/dev/null)
  SUBNETID=$(aws ec2 describe-subnets --filters Name=tag:Name,Values=$SUBNETNAME --query "Subnets[0].SubnetId" --output text $ACCOUNT_PROFILE 2>/dev/null)
  SUBNET_AZ=$(aws ec2 describe-subnets --filters Name=tag:Name,Values=$SUBNETNAME --query "Subnets[0].AvailabilityZoneId" --output text $ACCOUNT_PROFILE 2>/dev/null)
  SGID=$(aws ec2 describe-security-groups --filters Name=tag:Name,Values=ssh-access --query "SecurityGroups[0].GroupId" --output text $ACCOUNT_PROFILE 2>/dev/null)

  # Look for EFS mount target in caller account for the same availability zone ID (no costs if within same AZ) - Don't use name as name to IDs vary between accounts
  EFS_ID=$(aws efs describe-file-systems --query "FileSystems[?Name=='or-map-efs'].FileSystemId" --output text)
  EFS_DNS=$(aws efs describe-mount-targets --file-system-id $EFS_ID --query "MountTargets[?AvailabilityZoneId=='$SUBNET_AZ'].IpAddress" --output text)

  SUBNET_AZ=$(aws ec2 describe-subnets --filters Name=tag:Name,Values=$SUBNETNAME --query "Subnets[0].AvailabilityZone" --output text $ACCOUNT_PROFILE 2>/dev/null)

# Provision EBS data volume using CloudFormation (if stack doesn't already exist)
  echo "Provisioning EBS data volume"
  STATUS=$(aws cloudformation describe-stacks --stack-name $EBS_STACK_NAME --query "Stacks[0].StackStatus" --output text 2>/dev/null)

  if [ -n "$STATUS" ] && [ "$STATUS" != 'DELETE_COMPLETE' ]; then
      echo "Stack already exists for this host '$HOST' current status is '$STATUS'"
      STACK_ID=$(aws cloudformation describe-stacks --stack-name $EBS_STACK_NAME --query Stacks[0].StackId --output text 2>/dev/null)
  else

    if [ -f "${awsDir}cloudformation-create-ebs-volume.yml" ]; then
    EBS_TEMPLATE_PATH="${awsDir}cloudformation-create-ebs-volume.yml"
    elif [ -f ".ci_cd/aws/cloudformation-create-ebs-volume.yml" ]; then
    EBS_TEMPLATE_PATH=".ci_cd/aws/cloudformation-create-ebs-volume.yml"
    elif [ -f "openremote/.ci_cd/aws/cloudformation-create-ebs-volume.yml" ]; then
    EBS_TEMPLATE_PATH="openremote/.ci_cd/aws/cloudformation-create-ebs-volume.yml"
    else
        echo "Cannot determine location of cloudformation-create-ebs-volume.yml"
        exit 1
    fi

    # Configure parameters
    PARAMS="ParameterKey=Host,ParameterValue=$HOST"
    PARAMS="$PARAMS ParameterKey=AvailabilityZone,ParameterValue=$SUBNET_AZ"
    PARAMS="$PARAMS ParameterKey=DiskSize,ParameterValue=$DATA_DISK_SIZE"

    if [ -n "$SNAPSHOT_ID" ]; then
        PARAMS="$PARAMS ParameterKey=SnapshotId,ParameterValue='$SNAPSHOT_ID'"
    fi

    # Create standard stack resources in specified account
    EBS_STACK_ID=$(aws cloudformation create-stack --capabilities CAPABILITY_NAMED_IAM --stack-name $EBS_STACK_NAME --template-body file://$EBS_TEMPLATE_PATH --parameters $PARAMS --output text)

    if [ $? -ne 0 ]; then
      echo "Create stack failed"
      exit 1
    else
      echo "Create stack in progress"
    fi

    # Wait for CloudFormation stack status to be CREATE_*
    echo "Waiting for stack to be created"
    STATUS=$(aws cloudformation describe-stacks --stack-name $EBS_STACK_NAME --query "Stacks[?StackId=='$EBS_STACK_ID'].StackStatus" --output text 2>/dev/null)

    while [[ "$STATUS" == 'CREATE_IN_PROGRESS' ]]; do
        echo "Stack creation is still in progress .. Sleeping 30 seconds"
        sleep 30
        STATUS=$(aws cloudformation describe-stacks --stack-name $EBS_STACK_NAME --query "Stacks[?StackId=='$EBS_STACK_ID'].StackStatus" --output text 2>/dev/null)
    done

    if [ "$STATUS" != 'CREATE_COMPLETE' ]; then
        echo "Stack creation has failed status is '$STATUS'"
        exit 1
    else
        echo "Stack creation is complete"
    fi
  fi

  DEVICE_NAME="/dev/sdf" # Do not change unless you know what your doing.
  
  PARAMS="ParameterKey=EBSDeviceName,ParameterValue=$DEVICE_NAME"
  PARAMS="$PARAMS ParameterKey=Host,ParameterValue=$HOST"
  PARAMS="$PARAMS ParameterKey=VpcId,ParameterValue=$VPCID"
  PARAMS="$PARAMS ParameterKey=SSHSecurityGroupId,ParameterValue=$SGID"
  PARAMS="$PARAMS ParameterKey=SubnetId,ParameterValue=$SUBNETID"
  PARAMS="$PARAMS ParameterKey=EFSDNS,ParameterValue=$EFS_DNS"
  PARAMS="$PARAMS ParameterKey=SMTPHost,ParameterValue=$SMTP_HOST"

  if [ -n "$SMTP_USER" ]; then
    PARAMS="$PARAMS ParameterKey=SMTPUser,ParameterValue=$SMTP_USER"
  fi

  if [ -n "$SMTP_SECRET" ]; then
    PARAMS="$PARAMS ParameterKey=SMTPSecret,ParameterValue=$SMTP_SECRET ParameterKey=SMTPRegion,ParameterValue=$AWS_REGION"
  fi

  if [ -n "$INSTANCE_TYPE" ]; then
    PARAMS="$PARAMS ParameterKey=InstanceType,ParameterValue=$INSTANCE_TYPE"
  fi

  if [ -n "$DISK_SIZE" ]; then
    PARAMS="$PARAMS ParameterKey=DiskSize,ParameterValue=$DISK_SIZE"
  fi

  if [ -n "$ELASTIC_IP" ]; then
    PARAMS="$PARAMS ParameterKey=ElasticIP,ParameterValue=$ELASTIC_IP"
  fi

  if [ -n "$ENABLE_METRICS" ]; then
    PARAMS="$PARAMS ParameterKey=Metrics,ParameterValue=$ENABLE_METRICS"
  fi

  if [ -n "$DNSHostedZoneName" ]; then
    PARAMS="$PARAMS ParameterKey=DNSHostedZoneName,ParameterValue=$DNSHostedZoneName"
  fi

  if [ -n "$DNSHostedZoneRoleArn" ]; then
    PARAMS="$PARAMS ParameterKey=DNSHostedZoneRoleArn,ParameterValue=$DNSHostedZoneRoleArn"
  fi

  # Create standard stack resources in specified account
  STACK_ID=$(aws cloudformation create-stack --capabilities CAPABILITY_NAMED_IAM --stack-name $STACK_NAME --template-body file://$TEMPLATE_PATH --parameters $PARAMS --output text $ACCOUNT_PROFILE)

  if [ $? -ne 0 ]; then
    echo "Create stack failed"
    exit 1
  else
    echo "Create stack in progress"
  fi

  # Retrieve Instance ID and state before EBS data volume can be attached.
  INSTANCE_ID=$(aws ec2 describe-instances --filters "Name=tag:Name,Values='$HOST'" --query "Reservations[].Instances[?Tags[?Value=='$STACK_ID']].InstanceId" --output text $ACCOUNT_PROFILE 2>/dev/null)
  INSTANCE_STATE=$(aws ec2 describe-instances --filters "Name=tag:Name,Values='$HOST'" --query "Reservations[].Instances[?Tags[?Value=='$STACK_ID']].State.Name" --output text $ACCOUNT_PROFILE 2>/dev/null)

  # Check if instance is created and running
  echo "Check if instance is available"
  count=0
  while [[ -z "$INSTANCE_ID" ]] && [[ "$INSTANCE_STATE" != 'running' ]] && [ $count -lt 30 ]; do
      echo "Instance creation is still in progress .. Sleeping 30 seconds"
      sleep 30 
      INSTANCE_ID=$(aws ec2 describe-instances --filters "Name=tag:Name,Values='$HOST'" --query "Reservations[].Instances[?Tags[?Value=='$STACK_ID']].InstanceId" --output text $ACCOUNT_PROFILE 2>/dev/null)
      INSTANCE_STATE=$(aws ec2 describe-instances --filters "Name=tag:Name,Values='$HOST'" --query "Reservations[].Instances[?Tags[?Value=='$STACK_ID']].State.Name" --output text $ACCOUNT_PROFILE 2>/dev/null)
      count=$((count+1))
  done

  if [ -z "$INSTANCE_ID" ] && [ "$INSTANCE_STATE" != 'running' ]; then
    echo "Failed to provision instance"
    exit 1
  fi

  # Retrieve Volume ID and attach volume to Instance.
  echo "Instance is ready, attaching volume.."
  VOLUME_ID=$(aws ec2 describe-volumes --filters "Name=tag:Name,Values='$HOST/data'" --query "Volumes[?Tags[?Value=='$EBS_STACK_ID']].VolumeId" --output text $ACCOUNT_PROFILE 2>/dev/null)
  VOLUME=$(aws ec2 attach-volume --device $DEVICE_NAME --instance-id $INSTANCE_ID --volume-id $VOLUME_ID --output text $ACCOUNT_PROFILE 2>/dev/null)
  STATUS=$(aws ec2 describe-volumes --filters "Name=tag:Name,Values='$HOST/data'" --query "Volumes[?Tags[?Value=='$EBS_STACK_ID']].Attachments[].State" --output text $ACCOUNT_PROFILE 2>/dev/null)

  # Check if volume is attached
  while [[ "$STATUS" == 'attaching' ]]; do
      echo "Volume is still attaching .. Sleeping 30 seconds"
      sleep 30
      STATUS=$(aws ec2 describe-volumes --filters "Name=tag:Name,Values='$HOST/data'" --query "Volumes[?Tags[?Value=='$EBS_STACK_ID']].Attachments[].State" --output text $ACCOUNT_PROFILE 2>/dev/null)
  done

  if [ "$STATUS" != 'attached' ]; then
      echo "Volume attaching failed with status $STATUS"
      exit 1
  else
      echo "Volume attaching is complete"
  fi

  if [ "$WAIT_FOR_STACK" != 'false' ]; then
     # Wait for CloudFormation stack status to be CREATE_*
    echo "Waiting for stack to be created"
    STATUS=$(aws cloudformation describe-stacks --stack-name $STACK_NAME --query "Stacks[?StackId=='$STACK_ID'].StackStatus" --output text $ACCOUNT_PROFILE 2>/dev/null)

    while [[ "$STATUS" == 'CREATE_IN_PROGRESS' ]]; do
      echo "Stack creation is still in progress .. Sleeping 30 seconds"
      sleep 30
      STATUS=$(aws cloudformation describe-stacks --stack-name $STACK_NAME --query "Stacks[?StackId=='$STACK_ID'].StackStatus" --output text $ACCOUNT_PROFILE 2>/dev/null)
    done

    if [ "$STATUS" != 'CREATE_COMPLETE' ] && [ "$STATUS" != 'UPDATE_COMPLETE' ]; then
      echo "Stack creation has failed status is '$STATUS'"
      exit 1
     else
      echo "Stack creation is complete"
    fi
  fi
fi

# Provision DLM Policy
echo "Provisioning Lifecycle Policy for EBS Data volume"
STATUS=$(aws cloudformation describe-stacks --stack-name $DLM_STACK_NAME --query "Stacks[0].StackStatus" --output text 2>/dev/null)

if [ -n "$STATUS" ] && [ "$STATUS" != 'DELETE_COMPLETE' ]; then
  echo "Stack already exists for this host '$HOST' current status is '$STATUS'"
  STACK_ID=$(aws cloudformation describe-stacks --stack-name $DLM_STACK_NAME --query "Stacks[0].StackId" --output text 2>/dev/null)
else

  if [ -f "${awsDir}cloudformation-create-dlm-policy.yml" ]; then
    DLM_TEMPLATE_PATH="${awsDir}cloudformation-create-dlm-policy.yml"
  elif [ -f ".ci_cd/aws/cloudformation-create-dlm-policy.yml" ]; then
    DLM_TEMPLATE_PATH=".ci_cd/aws/cloudformation-create-dlm-policy.yml"
  elif [ -f "openremote/.ci_cd/aws/cloudformation-create-dlm-policy.yml" ]; then
    DLM_TEMPLATE_PATH="openremote/.ci_cd/aws/cloudformation-create-dlm-policy.yml"
  else
    echo "Cannot determine location of cloudformation-create-dlm-policy.yml"
    exit 1
  fi

  # Check for DLM IAM Role
  echo "Check if IAM Role exists"
  ROLE_ARN=$(aws iam get-role --role-name AWSDataLifecycleManagerDefaultRole --query "Role.Arn" --output text $ACCOUNT_PROFILE)

  if [ -z "$ROLE_ARN" ]; then
    ROLE=$(aws dlm create-default-role --resource-type snapshot)
      
    if [ $? -ne 0 ]; then
      echo "IAM Role creation has failed"
      exit 1
    else
      echo "IAM Role creation is complete"
    fi
      
    ROLE_ARN=$(aws iam get-role --role-name AWSDataLifecycleManagerDefaultRole --query "Role.Arn" --output text $ACCOUNT_PROFILE)
  fi

  # Configure parameters
  DLM_DESCRIPTION="OpenRemote-${HOST%.*}"
  PARAMS="ParameterKey=PolicyDescription,ParameterValue='$DLM_DESCRIPTION'"
  PARAMS="$PARAMS ParameterKey=DLMExecutionRoleArn,ParameterValue='$ROLE_ARN'"
  PARAMS="$PARAMS ParameterKey=EBSStackId,ParameterValue='$EBS_STACK_ID'"
  
  # Create standard stack resources in specified account
  STACK_ID=$(aws cloudformation create-stack --capabilities CAPABILITY_NAMED_IAM --stack-name $DLM_STACK_NAME --template-body file://$DLM_TEMPLATE_PATH --parameters $PARAMS --output text)

  if [ $? -ne 0 ]; then
    echo "Create stack failed"
    exit 1
  fi

  if [ "$WAIT_FOR_STACK" != 'false' ]; then
    # Wait for CloudFormation stack status to be CREATE_*
    echo "Waiting for stack to be created"
    STATUS=$(aws cloudformation describe-stacks --stack-name $DLM_STACK_NAME --query "Stacks[?StackId=='$STACK_ID'].StackStatus" --output text 2>/dev/null)

    while [[ "$STATUS" == 'CREATE_IN_PROGRESS' ]]; do
        echo "Stack creation is still in progress .. Sleeping 30 seconds"
        sleep 30
        STATUS=$(aws cloudformation describe-stacks --stack-name $DLM_STACK_NAME --query "Stacks[?StackId=='$STACK_ID'].StackStatus" --output text 2>/dev/null)
    done

    if [ "$STATUS" != 'CREATE_COMPLETE' ]; then
        echo "Stack creation has failed status is '$STATUS'"
        exit 1
    else
        echo "Stack creation is complete"
    fi
  fi
fi

# Provision SSM Documents
echo "Provisioning SSM Documents for attaching/detaching EBS Data volume"
STATUS=$(aws cloudformation describe-stacks --stack-name $SSM_STACK_NAME --query "Stacks[0].StackStatus" --output text 2>/dev/null)

if [ -n "$STATUS" ] && [ "$STATUS" != 'DELETE_COMPLETE' ]; then
  echo "Stack already exists for this host '$HOST' current status is '$STATUS'"
  STACK_ID=$(aws cloudformation describe-stacks --stack-name $SSM_STACK_NAME --query "Stacks[0].StackId" --output text 2>/dev/null)
else

  if [ -f "${awsDir}cloudformation-create-ssm-document" ]; then
    SSM_TEMPLATE_PATH="${awsDir}cloudformation-create-ssm-document.yml"
  elif [ -f ".ci_cd/aws/cloudformation-create-ssm-document.yml" ]; then
    SSM_TEMPLATE_PATH=".ci_cd/aws/cloudformation-create-ssm-document.yml"
  elif [ -f "openremote/.ci_cd/aws/cloudformation-create-ssm-document.yml" ]; then
    SSM_TEMPLATE_PATH="openremote/.ci_cd/aws/cloudformation-create-ssm-document.yml"
  else
    echo "Cannot determine location of cloudformation-create-ssm-document.yml"
    exit 1
  fi

  # Configure parameters
  PARAMS="ParameterKey=Host,ParameterValue='$HOST'"
  PARAMS="$PARAMS ParameterKey=InstanceId,ParameterValue='$INSTANCE_ID'"
  PARAMS="$PARAMS ParameterKey=VolumeId,ParameterValue='$VOLUME_ID'"
  PARAMS="$PARAMS ParameterKey=EBSDeviceName,ParameterValue='$DEVICE_NAME'"
  
  # Create standard stack resources in specified account
  STACK_ID=$(aws cloudformation create-stack --capabilities CAPABILITY_NAMED_IAM --stack-name $SSM_STACK_NAME --template-body file://$SSM_TEMPLATE_PATH --parameters $PARAMS --output text)

  if [ $? -ne 0 ]; then
    echo "Create stack failed"
    exit 1
  fi

  if [ "$WAIT_FOR_STACK" != 'false' ]; then
    # Wait for CloudFormation stack status to be CREATE_*
    echo "Waiting for stack to be created"
    STATUS=$(aws cloudformation describe-stacks --stack-name $SSM_STACK_NAME --query "Stacks[?StackId=='$STACK_ID'].StackStatus" --output text 2>/dev/null)

    while [[ "$STATUS" == 'CREATE_IN_PROGRESS' ]]; do
        echo "Stack creation is still in progress .. Sleeping 30 seconds"
        sleep 30
        STATUS=$(aws cloudformation describe-stacks --stack-name $SSM_STACK_NAME --query "Stacks[?StackId=='$STACK_ID'].StackStatus" --output text 2>/dev/null)
    done

    if [ "$STATUS" != 'CREATE_COMPLETE' ]; then
        echo "Stack creation has failed status is '$STATUS'"
        exit 1
    else
        echo "Stack creation is complete"
    fi
  fi
fi

# Provision S3 bucket
if [ "$PROVISION_S3_BUCKET" != 'false' ]; then
  echo "Provisioning S3 bucket for host '$HOST'"

  BUCKET=$(aws s3api list-buckets --query "Buckets[?Name=='$HOST'].Name" --output text $ACCOUNT_PROFILE)

  if [ -n "$BUCKET" ]; then
    echo "Bucket for this host already exists"
  else
    LOCATION=$(aws s3api create-bucket --bucket $HOST --acl private --create-bucket-configuration LocationConstraint=$AWS_REGION --output text $ACCOUNT_PROFILE)
    if [ $? -ne 0 ]; then
      echo "Bucket creation failed"
    else
      echo "Bucket created successfully '$LOCATION'"
      aws s3api put-bucket-versioning --bucket $HOST --versioning-configuration Status=Enabled $ACCOUNT_PROFILE
      aws s3api put-public-access-block --bucket $HOST --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true" $ACCOUNT_PROFILE
    fi
  fi
fi

# Provision Route 53 healthcheck alarm cloud formation (if stack doesn't already exist) - must be in the us-east-1 region
echo "Provisioning Healthcheck Alarm"
STATUS=$(aws cloudformation describe-stacks --stack-name $HEALTH_STACK_NAME --query "Stacks[0].StackStatus" --output text $ACCOUNT_PROFILE --region us-east-1 2>/dev/null)

if [ -n "$STATUS" ] && [ "$STATUS" != 'DELETE_COMPLETE' ]; then
  echo "Stack already exists for this host's Healthcheck '$HEALTH_STACK_NAME' current status is '$STATUS'"
  STACK_ID=$(aws cloudformation describe-stacks --stack-name $HEALTH_STACK_NAME --query "Stacks[0].StackId" --output text $ACCOUNT_PROFILE --region us-east-1 2>/dev/null)
else

  if [ -f "${awsDir}cloudformation-healthcheck-alarm.yml" ]; then
    HEALTH_TEMPLATE_PATH="${awsDir}cloudformation-healthcheck-alarm.yml"
  elif [ -f ".ci_cd/aws/cloudformation-healthcheck-alarm.yml" ]; then
    HEALTH_TEMPLATE_PATH=".ci_cd/aws/cloudformation-healthcheck-alarm.yml"
  elif [ -f "openremote/.ci_cd/aws/cloudformation-healthcheck-alarm.yml" ]; then
    HEALTH_TEMPLATE_PATH="openremote/.ci_cd/aws/cloudformation-healthcheck-alarm.yml"
  else
    echo "Cannot determine location of cloudformation-healthcheck-alarm.yml"
    exit 1
  fi

  #Configure parameters
  PARAMS="ParameterKey=Host,ParameterValue='$HOST'"

  # Create standard stack resources in specified account in us-east-1 region
  STACK_ID=$(aws cloudformation create-stack --stack-name $HEALTH_STACK_NAME --template-body file://$HEALTH_TEMPLATE_PATH --parameters $PARAMS --output text $ACCOUNT_PROFILE --region us-east-1)

  if [ $? -ne 0 ]; then
    echo "Create stack failed"
    exit 1
  fi

  if [ "$WAIT_FOR_STACK" != 'false' ]; then
    # Wait for cloud formation stack status to be CREATE_*
    echo "Waiting for stack to be created"
    STATUS=$(aws cloudformation describe-stacks --stack-name $HEALTH_STACK_NAME --query "Stacks[?StackId=='$STACK_ID'].StackStatus" --output text $ACCOUNT_PROFILE --region us-east-1 2>/dev/null)

    while [[ "$STATUS" == 'CREATE_IN_PROGRESS' ]]; do
      echo "Stack creation is still in progress .. Sleeping 30 seconds"
      sleep 30
      STATUS=$(aws cloudformation describe-stacks --stack-name $HEALTH_STACK_NAME --query "Stacks[?StackId=='$STACK_ID'].StackStatus" --output text $ACCOUNT_PROFILE --region us-east-1 2>/dev/null)
    done

    if [ "$STATUS" != 'CREATE_COMPLETE' ]; then
      echo "Stack creation has failed status is '$STATUS'"
      exit 1
    else
      echo "Stack creation is complete"
    fi
  fi
fi
