STACK_NAME=Volume
STACK_NAME2=Machine
TEMPLATE_PATH=file://cloudformation-create-ebs-volume.yml
TEMPLATE_PATH2=file://cloudformation-create-ec2.yml
PARAMS="ParameterKey=Hostname,ParameterValue=kuijs.me ParameterKey=AvailabilityZone,ParameterValue=eu-west-1a ParameterKey=SnapshotId,ParameterValue=snap-0d909df4be805491d"

STACK_ID=$(aws cloudformation create-stack --stack-name $STACK_NAME --template-body $TEMPLATE_PATH --parameters $PARAMS --output text)

echo "Waiting for stack to be created"
STATUS=$(aws cloudformation describe-stacks --stack-name $STACK_NAME --query "Stacks[?StackId=='$STACK_ID'].StackStatus" --output text)

while [[ "$STATUS" == "CREATE_IN_PROGRESS" ]]; do
    echo "Stack creation is still in progress .. Sleeping 30 seconds"
    sleep 30
    STATUS=$(aws cloudformation describe-stacks --stack-name $STACK_NAME --query "Stacks[?StackId=='$STACK_ID'].StackStatus" --output text)
done

if [ "$STATUS" != 'CREATE_COMPLETE' ]; then
    echo "Stack creation has failed status is '$STATUS'"
    exit 1;
else
    echo "Stack creation is complete"
fi

VOLUME_ID=$(aws ec2 describe-volumes --filters "Name=tag:aws:cloudformation:stack-id,Values='$STACK_ID'" --query "Volumes[].VolumeId" --output text) 

PARAMS="ParameterKey=Keypair,ParameterValue=OpenRemote"
STACK_ID=$(aws cloudformation create-stack --stack-name $STACK_NAME2 --template-body $TEMPLATE_PATH2 --parameters $PARAMS --output text)

echo "Waiting for stack to be created"
STATUS=$(aws cloudformation describe-stacks --stack-name $STACK_NAME2 --query "Stacks[?StackId=='$STACK_ID'].StackStatus" --output text)

while [[ "$STATUS" == "CREATE_IN_PROGRESS" ]]; do
    STATE=$(aws ec2 describe-volumes --filters "Name=volume-id,Values='$VOLUME_ID'" --query "Volumes[].State" --output text)

    if [ $STATE != "in-use" ]; then
        echo "Check if instance is already available"
    
        INSTANCE_ID=$(aws ec2 describe-instances --filters "Name=tag:aws:cloudformation:stack-id,Values='$STACK_ID'" --query "Reservations[].Instances[].InstanceId" --output text)
        while [[ -z "$INSTANCE_ID" ]]; do
            echo "Instance is not created yet.. Sleep for 30 seconds"
            sleep 30
            INSTANCE_ID=$(aws ec2 describe-instances --filters "Name=tag:aws:cloudformation:stack-id,Values='$STACK_ID'" --query "Reservations[].Instances[].InstanceId" --output text)
        done

        echo "Instance found with id $INSTANCE_ID, attaching volume"
        INSTANCE_STATE=$(aws ec2 describe-instances --filters "Name=tag:aws:cloudformation:stack-id,Values='$STACK_ID'" --query "Reservations[].Instances[].State.Name" --output text)
        
        while [[ "$INSTANCE_STATE" != "running" ]]; do
            echo "Instance is not running.. Sleep for 5 seconds $INSTANCE_STATE"
            sleep 5
            INSTANCE_STATE=$(aws ec2 describe-instances --filters "Name=tag:aws:cloudformation:stack-id,Values='$STACK_ID'" --query "Reservations[].Instances[].State.Name" --output text)
        done

        if [ "$INSTANCE_STATE" == "running" ]; then
            VOLUME=$(aws ec2 attach-volume --device /dev/sdf --instance-id $INSTANCE_ID --volume-id $VOLUME_ID)

            STATE=$(aws ec2 describe-volumes --filters "Name=volume-id,Values='$VOLUME_ID'" --query "Volumes[].State" --output text)
            while [[ "$STATE" == "attaching" ]]; do
                echo "Volume still attaching.. Sleep for 5 seconds"
                sleep 5
                STATE=$(aws ec2 describe-volumes --filters "Name=volume-id,Values='$VOLUME_ID'" --query "Volumes[].State" --output text)
            done

            if [ "$STATE" != "in-use" ]; then
                echo "Volume mounting is failed with status $STATE"
                exit 1;
            else
                echo "Volume mounted!"
            fi
        fi
    fi
    echo "Stack creation is still in progress.. Sleeping 30 seconds"
    sleep 30
    STATUS=$(aws cloudformation describe-stacks --stack-name $STACK_NAME2 --query "Stacks[?StackId=='$STACK_ID'].StackStatus" --output text)
done

if [ "$STATUS" != 'CREATE_COMPLETE' ]; then
    echo "Stack creation has failed status is '$STATUS'"
    exit 1;
else
    echo "Stack creation is complete"
fi