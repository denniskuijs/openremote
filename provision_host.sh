HOST=${1,,}
SNAPSHOT_ID=${5,,}
AVAILABILTYZONE="eu-west-1a"
WAIT_FOR_STACK="true"
awsDir=./

if [ -z "$AWS_REGION" ]; then
  AWS_REGION=eu-west-1
fi

if [ -n "$AWS_ACCESS_KEY_ID" ]; then
  aws configure --profile github set aws_access_key_id $AWS_ACCESS_KEY_ID
fi

if [ -n "$AWS_SECRET_ACCESS_KEY" ]; then
  aws configure --profile github set aws_secret_access_key $AWS_SECRET_ACCESS_KEY
fi

if [ -n "$AWS_REGION" ]; then
  aws configure --profile github set region $AWS_REGION
  aws configure --profile github-da set region $AWS_REGION
fi

AWS_PROFILE=github
export AWS_PROFILE=$AWS_PROFILE

echo "Validating AWS credentials"
aws sts get-caller-identity

if [ $? -ne 0 ]; then
  echo "Failed to login to AWS"
  exit 1
else
  echo "Login succeeded"
  AWS_ENABLED=true
fi

STACK_NAME=$(tr '.' '-' <<< "$HOST")
EBS_STACK_NAME="$STACK_NAME-ebs-volume"

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

echo "Provisioning EBS Volume"
STATUS=$(aws cloudformation describe-stacks --stack-name $EBS_STACK_NAME --query "Stacks[].StackStatus" --output text 2>/dev/null)

if [ -n "$STATUS" ] && [ "$STATUS" != "DELETE_COMPLETE" ]; then
    echo "Stack already exists for this host '$HOST' current status is '$STATUS'"
    STACK_ID=$(aws cloudformation describe-stacks --stack-name $EBS_STACK_NAME --query Stacks[].StackId --output text)
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

    PARAMS="$PARAMS ParameterKey=Hostname,ParameterValue=$HOST"
    PARAMS="$PARAMS ParameterKey=AvailabilityZone,ParameterValue=$AVAILABILTYZONE"
    
    if [ -n $SNAPSHOT_ID ]; then
        PARAMS="$PARAMS ParameterKey=SnapshotId,ParameterValue=$SNAPSHOT_ID"
    fi

    STACK_ID=$(aws cloudformation create-stack --stack-name $EBS_STACK_NAME --template-body file://$EBS_TEMPLATE_PATH --parameters $PARAMS --output text)

    echo "Waiting for stack to be created"
    STATUS=$(aws cloudformation describe-stacks --stack-name $EBS_STACK_NAME --query "Stacks[?StackId=='$STACK_ID'].StackStatus" --output text)

    while [[ "$STATUS" == "CREATE_IN_PROGRESS" ]]; do
        echo "Stack creation is still in progress .. Sleeping 30 seconds"
        sleep 30
        STATUS=$(aws cloudformation describe-stacks --stack-name $EBS_STACK_NAME --query "Stacks[?StackId=='$STACK_ID'].StackStatus" --output text)
    done

    if [ "$STATUS" != 'CREATE_COMPLETE' ]; then
        echo "Stack creation has failed status is '$STATUS'"
        exit 1;
    else
        echo "Stack creation is complete"
    fi
fi

PARAMS="ParameterKey=Keypair,ParameterValue=OpenRemote"
STACK_ID=$(aws cloudformation create-stack --stack-name $STACK_NAME --template-body file://$TEMPLATE_PATH --parameters $PARAMS --output text)

INSTANCE_ID=$(aws ec2 describe-instances --filters "Name=tag:aws:cloudformation:stack-id,Values='$STACK_ID'" --query "Reservations[].Instances[].InstanceId" --output text)
INSTANCE_STATE=$(aws ec2 describe-instances --filters "Name=tag:aws:cloudformation:stack-id,Values='$STACK_ID'" --query "Reservations[].Instances[].State.Name" --output text)

echo "Check if instance is available"
while [[ -z "$INSTANCE_ID" ]] && [[ "$INSTANCE_STATE" != "running" ]]; do
    echo "Instance creation is still in progress.. Sleeping 30 seconds"
    sleep 30 
    INSTANCE_ID=$(aws ec2 describe-instances --filters "Name=tag:aws:cloudformation:stack-id,Values='$STACK_ID'" --query "Reservations[].Instances[].InstanceId" --output text)
    INSTANCE_STATE=$(aws ec2 describe-instances --filters "Name=tag:aws:cloudformation:stack-id,Values='$STACK_ID'" --query "Reservations[].Instances[].State.Name" --output text)
done

echo "Instance is ready, attaching volume.."
VOLUME_ID=$(aws ec2 describe-volumes --filters "Name=tag:aws:cloudformation:stack-name,Values='$EBS_STACK_NAME'" --query "Volumes[].VolumeId" --output text)
VOLUME_STATE=$(aws ec2 attach-volume --device /dev/sdf --instance-id $INSTANCE_ID --volume-id $VOLUME_ID --query "State" --output text)

while [[ "$VOLUME_STATE" == "attaching" ]]; do
    echo "Volume is still attaching.. Sleeping 30 seconds"
    sleep 30
    VOLUME_STATE=$(aws ec2 describe-volumes --filters "Name=tag:aws:cloudformation:stack-name,Values='$EBS_STACK_NAME'" --query "Volumes[].State" --output text)
done

if [ "$VOLUME_STATE" != "in-use" ]; then
    echo "Volume attaching failed with status $VOLUME_STATE"
    exit 1;
else
    echo "Volume $VOLUME_ID is attached to instance $INSTANCE_ID"
fi


if [ "$WAIT_FOR_STACK" != "false" ]; then
    echo "Waiting for stack to be created"
    STATUS=$(aws cloudformation describe-stacks --stack-name $STACK_NAME --query "Stacks[?StackId=='$STACK_ID'].StackStatus" --output text)

    while [[ "$STATUS" == "CREATE_IN_PROGRESS" ]]; do
        echo "Stack creation is still in progress.. Sleeping 30 seconds"
        sleep 30
        STATUS=$(aws cloudformation describe-stacks --stack-name $STACK_NAME --query "Stacks[?StackId=='$STACK_ID'].StackStatus" --output text)
    done

    if [ "$STATUS" != 'CREATE_COMPLETE' ] && [ "$STATUS" != 'UPDATE_COMPLETE' ]; then
        echo "Stack creation has failed status is '$STATUS'"
        exit 1;
    else
        echo "Stack creation is complete"
    fi
fi