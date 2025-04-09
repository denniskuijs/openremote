<!-- title: Implementation: Separate EBS Volume -->

## Implementation: Separate EBS Volume  <!-- omit in toc -->

## Context
This document provides a detailed explanation of how I implemented the creation and mounting of the separate EBS volume within the CI/CD pipeline. It also outlines the decisions I made and the challenges I encountered during development.

## Contents <!-- omit in toc -->

<style>
  .toc > ul { padding-left: 1em; }
  .toc > * * ul { padding-left: 1em; }
  .toc > * > li { list-style-type: none; }
  .toc > * * > li { list-style-type: none; }
</style>

<div class="toc">

- [Context](#context)
- [1. Research based on feedback](#1-research-based-on-feedback)
  - [1.1. Mount EBS volume on the Docker volumes directory](#11-mount-ebs-volume-on-the-docker-volumes-directory)
- [2. Implementation in the CI/CD pipeline](#2-implementation-in-the-cicd-pipeline)
  - [2.1. Creating/Mounting the EBS data volume](#21-creatingmounting-the-ebs-data-volume)
    - [2.1.1. GitHub Actions Workflow](#211-github-actions-workflow)
    - [2.1.2. Provision Host Script](#212-provision-host-script)
    - [2.1.3. CloudFormation Template](#213-cloudformation-template)
  - [2.2. Adding CloudWatch metrics/alarms for the EBS data volume](#22-adding-cloudwatch-metricsalarms-for-the-ebs-data-volume)
    - [2.2.1. CloudFormation Template](#221-cloudformation-template)
  - [2.3. Adding support for automatic snapshot creation of the EBS data volume](#23-adding-support-for-automatic-snapshot-creation-of-the-ebs-data-volume)
    - [2.3.1. Provision Host Script](#231-provision-host-script)
    - [2.3.2. CloudFormation Template](#232-cloudformation-template)

</div>

## 1. Research based on feedback
After completing my initial research, I discussed my findings with several team members. Based on their feedback, I continued my research on this topic before starting the implementation of my prototype in the CI/CD pipeline.

### 1.1. Mount EBS volume on the Docker volumes directory
One of the team members suggested mounting the default Docker volumes directory (`/var/lib/docker/volumes`) to the newly created EBS volume, instead of creating/mounting an custom directory. \
I start investigating this option by mounting the separate EBS volume to this directory with the following command:

```sh
sudo mount /dev/sdf /var/lib/docker/volumes
```

This works without any issues, when I check the volume mountpoints with the command.

```sh
sudo lsblk -f
```

It shows that the volume is mounted on the default volume location from `Docker` (`/var/lib/docker/volumes`)

<img src="../assets/image/ec2-docker-volume-default-location.png" width="800">

After starting OpenRemote with the default `Docker Compose` file everything is booting up properly without any issues whatsoever.

<img src="../assets/image/ec2-openremote-healthy.png" width="800">

However, after attaching the EBS volume to another `EC2` instance running OpenRemote, I encountered permission errors again with the `PostgresSQL` Container.

<img src="../assets/image/ec2-docker-volume-permission-error-postgres.png" width="800">

Based on the knowledge of my initial research, I knew that this issue could be resolved by setting the `PGDATA` environment variable in the `Docker Compose` file. \
Since the `EBS` volume is an external block device, this step is nessecary for `Docker` to properly access the data. It's not possible to `chown` the directory to both the `postgres` and `root` users simultaneously, which makes specifying the `PGDATA` variable essential.

After adding the `PGDATA` variable the `Docker Compose` file looks like this

```

# OpenRemote v3
#
# Profile that runs the stack by default on https://localhost using a self-signed SSL certificate,
# but optionally on https://$OR_HOSTNAME with an auto generated SSL certificate from Letsencrypt.
#
# It is configured to use the AWS logging driver.
#
volumes:
  proxy-data:
  manager-data:
  postgresql-data:

services:

  proxy:
    image: openremote/proxy:${PROXY_VERSION:-latest}
    restart: always
    depends_on:
      manager:
        condition: service_healthy
    ports:
      - 80:80 # Needed for SSL generation using letsencrypt
      - ${OR_SSL_PORT:-443}:443
      - 8883:8883
      - 127.0.0.1:8404:8404 # Localhost metrics access
    volumes:
      - proxy-data:/deployment
    environment:
      LE_EMAIL: ${OR_EMAIL_ADMIN:-}
      DOMAINNAME: ${OR_HOSTNAME:-localhost}
      DOMAINNAMES: ${OR_ADDITIONAL_HOSTNAMES:-}
      # USE A CUSTOM PROXY CONFIG - COPY FROM https://raw.githubusercontent.com/openremote/proxy/main/haproxy.cfg
      # HAPROXY_CONFIG: '/data/proxy/haproxy.cfg'

  postgresql:
    restart: always
    image: openremote/postgresql:${POSTGRESQL_VERSION:-latest}
    shm_size: 128mb
    volumes:
      - postgresql-data:/var/lib/postgresql/data
      - manager-data:/storage
    environment:
      PGDATA: /var/lib/postgresql/data/postgres

  keycloak:
    restart: always
    image: openremote/keycloak:${KEYCLOAK_VERSION:-latest}
    depends_on:
      postgresql:
        condition: service_healthy
    volumes:
      - ./deployment:/deployment
    environment:
      KEYCLOAK_ADMIN_PASSWORD: ${OR_ADMIN_PASSWORD:-secret}
      KC_HOSTNAME: ${OR_HOSTNAME:-localhost}
      KC_HOSTNAME_PORT: ${OR_SSL_PORT:--1}


  manager:
  # privileged: true
    restart: always
    image: openremote/manager:${MANAGER_VERSION:-latest}
    depends_on:
      keycloak:
        condition: service_healthy
    ports:
      - 127.0.0.1:8405:8405 # Localhost metrics access
    environment:
      OR_SETUP_TYPE:
      OR_ADMIN_PASSWORD:
      OR_SETUP_RUN_ON_RESTART:
      OR_EMAIL_HOST:
      OR_EMAIL_USER:
      OR_EMAIL_PASSWORD:
      OR_EMAIL_X_HEADERS:
      OR_EMAIL_FROM:
      OR_EMAIL_ADMIN:
      OR_METRICS_ENABLED: ${OR_METRICS_ENABLED:-true}
      OR_HOSTNAME: ${OR_HOSTNAME:-localhost}
      OR_ADDITIONAL_HOSTNAMES:
      OR_SSL_PORT: ${OR_SSL_PORT:--1}
      OR_DEV_MODE: ${OR_DEV_MODE:-false}

      # The following variables will configure the demo
      OR_FORECAST_SOLAR_API_KEY:
      OR_OPEN_WEATHER_API_APP_ID:
      OR_SETUP_IMPORT_DEMO_AGENT_KNX:
      OR_SETUP_IMPORT_DEMO_AGENT_VELBUS:
    volumes:
      - manager-data:/storage

```

With this setup, the `EBS` volume can now easily be attached to other `EC2` instances as long as the `PGDATA` variable is configured on both the original and target machine.
Additionally, the `Docker Compose` file becomes much simpeler, only the `PGDATA` variable needs to be configured, eliminating the need to define different volume paths for each individual container.

## 2. Implementation in the CI/CD pipeline
In this section I will explain how I have implemented my prototype in the existing CI/CD pipeline on `Github Actions`. It will be devided into the following topics.
  
  - Creating/Mounting the EBS data volume
  - Adding CloudWatch metrics/alarms for the EBS data volume
  - Adding support for automatic snapshot creation of the EBS data volume
  - Adding support for automatic attaching/detaching the EBS data volume

### 2.1. Creating/Mounting the EBS data volume

#### 2.1.1. GitHub Actions Workflow
I started my implementation in the GitHub Actions workflow. In this file the steps for executing the CI/CD pipeline are described.
The workflow will run on `workflow dispatch` which means on-demand without the need for opening a pull-request or pushing code.

```
on:
  workflow_dispatch:
```

I've added two additional input variables to this file: `DATA_DISK_SIZE` and `SNAPSHOT_ID`.

The `DATA_DISK_SIZE` variable allows you to specify the desired size of the data `EBS` volume. By default, it is set to 16, matching the size of the `root` device.
```
DATA_DISK_SIZE:
  description: 'Override EC2 data EBS volume size (GB)'
    type: string
    default: '16'
    required: false
```

The `SNAPSHOT_ID` variable allows you to specify an `Snapshot` that will be used for creating the `EBS` data volume, allowing you to create an volume based of existing data. \
When this variable is specified the `DATA_DISK_SIZE` parameter is ignored. Instead, the volume will be provisioned with the same amount of storage that was assigned before snapshot creation.

```
SNAPSHOT_ID:
  description: 'Create EBS data volume based on snapshot'
  type: string
  required: false
```

Next, I added the input variables to the `.env` section in the `provision host` step. This ensures that the variable values can be accessed by referencing the input section at the top, like this:

```
  env:
    ACCOUNT_NAME: ${{ github.event.inputs.ACCOUNT_NAME }}
    HOST: ${{ github.event.inputs.HOST }}
    INSTANCE_TYPE: ${{ github.event.inputs.INSTANCE_TYPE }}
    ROOT_DISK_SIZE: ${{ github.event.inputs.ROOT_DISK_SIZE }}
    DATA_DISK_SIZE: ${{ github.event.inputs.DATA_DISK_SIZE }}
    SNAPSHOT_ID: ${{ github.event.inputs.SNAPSHOT_ID }}
    ELASTIC_IP: ${{ github.event.inputs.ELASTIC_IP }}
    PROVISION_S3_BUCKET: ${{ github.event.inputs.PROVISION_S3_BUCKET }}
    AWS_ACCESS_KEY_ID: ${{ secrets._TEMP_AWS_ACCESS_KEY_ID }}
    AWS_SECRET_ACCESS_KEY: ${{ secrets._TEMP_AWS_SECRET_ACCESS_KEY }}
    AWS_ROLE_NAME: ${{ secrets._TEMP_AWS_ROLE_NAME }}
    ENABLE_METRICS: ${{ github.event.inputs.ENABLE_METRICS }}

```

Finally, I passed the newly created variables to the `provision_host.sh` script. This ensures that the script can access the variable values and execute its logic based on them.

```
.ci_cd/aws/provision_host.sh "$ACCOUNT_NAME" "$HOST" "$INSTANCE_TYPE" "$ROOT_DISK_SIZE" "$DATA_DISK_SIZE" "$SNAPSHOT_ID" "$ELASTIC_IP" "$PROVISION_S3_BUCKET" "$ENABLE_METRICS"
```

#### 2.1.2. Provision Host Script
In the `provision host` script, I started modifying the order of the variables that are passed from the `workflow` to the script. In bash, you can reference each variable based on the order in which they are passed.

```

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

```

After that, I created the `EBS_STACK_NAME` variable, which generates a unique name for the CloudFormation stack by combining the `STACK_NAME` with a predefined text string. The `STACK_NAME` itself is created from the `HOST` variable, where all dots in the `hostname` are replaced with a separator. With this apparoach, the `CloudFormation` stack names are unique for every `host`.

It is important that the `EBS` volume will be created in the same `Availabilty Zone` as the `EC2` instance, otherwise it is not possible to attach the volume to the instance. To achieve this, I first investigated how the `EC2` instance is assigned to a specific `Availabilty Zone`.

First, the `SUBNET_NUMBER` variable is set using an random integer between 1 and 3. There are 3 different `public subnets` and this apparoach randomly selects one of them. Each subnet resides in a different `Availabilty Zone`, 1a, 1b or 1c. The subnet name is generated using the `SUBNET_NUMBER` variable and a predefined text string.

```

SUBNET_NUMBER=$(( $RANDOM % 3 + 1 ))
SUBNETNAME="or-subnet-public-$SUBNET_NUMBER"

```

I still needed the exact `Availabilty Zone` name that the `EC2` instance will use. The script already includes a line that retrieves the `AvailabiltyZoneId` based on the `SUBNET_NAME` variable. However, this ID cannot be used to to create the `EBS` volume, as the volume requires the `Availabilty Zone` name, not the ID, to resolve this, I added the following line to the script to retrieve the name.

```
SUBNET_AZ=$(aws ec2 describe-subnets --filters Name=tag:Name,Values=$SUBNETNAME --query "Subnets[0].AvailabilityZone" --output text $ACCOUNT_PROFILE 2>/dev/null)
```

After setting the `Availabilty Zone` name in the `SUBNET_AZ` variable I can start creating the `EBS` volume. 
The volume creation is handeled by a seperate `CloudFormation` template to ensure that the `EBS` volume will not be affected by template updates at the `EC2` machine. 

Before the `EBS` volume is created I first check if the stack not already exists

```

STATUS=$(aws cloudformation describe-stacks --stack-name $EBS_STACK_NAME --query "Stacks[0].StackStatus" --output text 2>/dev/null)

if [ -n "$STATUS" ] && [ "$STATUS" != 'DELETE_COMPLETE' ]; then
    echo "Stack already exists for this host '$HOST' current status is '$STATUS'"
    EBS_STACK_ID=$(aws cloudformation describe-stacks --stack-name $EBS_STACK_NAME --query Stacks[0].StackId --output text 2>/dev/null)
else

```

If the stack exists the `EBS_STACK_ID` variable will be set with the Stack ID for future reference. Otherwise the `EBS` volume will be created.
When creating the volume I first check if the `CloudFormation` template exists in one of the specified directories. If this is not the case, the script will exit and throw an error since the template cannot be found.

```

if [ -f "${awsDir}cloudformation-create-ebs-volume.yml" ]; then
  EBS_TEMPLATE_PATH="${awsDir}cloudformation-create-ebs-volume.yml"
  elif [ -f ".ci_cd/aws/cloudformation-create-ebs-volume.yml" ]; then
  EBS_TEMPLATE_PATH=".ci_cd/aws/cloudformation-create-ebs-volume.yml"
    lif [ -f "openremote/.ci_cd/aws/cloudformation-create-ebs-volume.yml" ]; then
  EBS_TEMPLATE_PATH="openremote/.ci_cd/aws/cloudformation-create-ebs-volume.yml"
  else
    echo "Cannot determine location of cloudformation-create-ebs-volume.yml"
    exit 1
fi

```

After that I will set the `HOST`, `AvailabilityZone` and `DiskSize` parameters that are specified in the `CloudFormation` template and required for creating the volume. The values are coming from the `workflow` inputs or are generated earlier in the script.

```

PARAMS="ParameterKey=Host,ParameterValue=$HOST"
PARAMS="$PARAMS ParameterKey=AvailabilityZone,ParameterValue=$SUBNET_AZ"
PARAMS="$PARAMS ParameterKey=DiskSize,ParameterValue=$DATA_DISK_SIZE"

```

When the `SNAPSHOT_ID` variable is provided, this parameter will be configured to ensure that the volume is created based of an existing snapshot.

```

if [ -n "$SNAPSHOT_ID" ]; then
  PARAMS="$PARAMS ParameterKey=SnapshotId,ParameterValue='$SNAPSHOT_ID'"
fi

```

After configuring the parameters the `CloudFormation` stack will be created with the following command. 
In this command I specify the stack name that was generated at the beginning of the script and also pass the configured parameters.

```

EBS_STACK_ID=$(aws cloudformation create-stack --capabilities CAPABILITY_NAMED_IAM --stack-name $EBS_STACK_NAME --template-body file://$EBS_TEMPLATE_PATH --parameters $PARAMS --output text)

```
When the stack is successfully created it will return the Stack ID, which will then be stored in the `EBS_STACK_ID` variable. 
The code below checks if the previous command, the creation of the `CloudFormation` Stack succeeds, if not, the script will throw an exit code and stops.

```

if [ $? -ne 0 ]; then
  echo "Create stack failed"
  exit 1
else
  echo "Create stack in progress"
fi

```

After the stack is successfully created, we need to check whether the creation was succesfull or failed with an error. The code below retrieves the status from the `CloudFormation` stack based of the Stack ID that was stored in the previous step. As long as the status returns `CREATE_IN_PROGRESS` the stack will still be created. The script retrieves the stack status every 30 seconds and will stop when the status either returns `CREATE_COMPLETE` (stack creation succesfull) or when the status is not `CREATE_IN_PROGRESS` and also not `CREATE_COMPLETED` (stack creation failed).

```

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

```

When the `EBS` volume is created succesfully it can be attached to the `EC2` instance. To attach the volume to a instance you must specify an `Device Name` such as `/dev/sda`, `/dev/sdb` etc. It is not possible to automatically assign an `device name` upon attaching, you must specify an specific `device name` upfront that needs to be used. To achieve this, I have configured a variable with the name `EBS_DEVICE_NAME` and set it to the `/dev/sdf` `device name`.

<img src="../assets/image/ebs-volume-virtualization.png" width="800">

As visible in the picture above, for `EC2` instances that are using `HVM` as virtualization method it is recommended to choose a `device name` between `/dev/sd[b]` and `/dev/sd[z]`.

Attaching the volume to the EC2 instance is a technical process that involves several logical steps. 
First, before the `EBS` volume can be mounted there must of course be a running `EC2` instance. To check this I retrieve the Instance ID and state from the `CloudFormation` stack that creates the `EC2` instance.

```

INSTANCE_ID=$(aws ec2 describe-instances --filters "Name=tag:Name,Values='$HOST'" --query "Reservations[].Instances[?Tags[?Value=='$STACK_ID']].InstanceId" --output text $ACCOUNT_PROFILE 2>/dev/null)
INSTANCE_STATE=$(aws ec2 describe-instances --filters "Name=tag:Name,Values='$HOST'" --query "Reservations[].Instances[?Tags[?Value=='$STACK_ID']].State.Name" --output text $ACCOUNT_PROFILE 2>/dev/null)

```

The script will check for an `EC2` instance that belongs to the `CloudFormation` template by quering on the specifc `Stack ID` that was returned when this stack was successfully created. To make sure we always target the correct instance, an filter will be applied to get the instance with the name that is provided in the `CloudFormation` template.
The script will also retrieve the status from the machine as it is only possible to attach volumes to a `running` instance.

```

echo "Check if instance is available"
count=0
while [[ -z "$INSTANCE_ID" ]] && [[ "$INSTANCE_STATE" != 'running' ]] && [ $count -lt 30 ]; do
    echo "Instance creation is still in progress .. Sleeping 30 seconds"
    sleep 30 
    INSTANCE_ID=$(aws ec2 describe-instances --filters "Name=tag:Name,Values='$HOST'" --query "Reservations[].Instances[?Tags[?Value=='$STACK_ID']].InstanceId" --output text $ACCOUNT_PROFILE 2>/dev/null)
    INSTANCE_STATE=$(aws ec2 describe-instances --filters "Name=tag:Name,Values='$HOST'" --query "Reservations[].Instances[?Tags[?Value=='$STACK_ID']].State.Name" --output text $ACCOUNT_PROFILE 2>/dev/null)
    count=$((count+1))
done

```

If the Instance ID is not found or the instance status is not `running`, the script waits for 30 seconds before retrying. Each attempt increments a counter, and the script continues checking as long as the counter remains below 30. This counter acts as a safeguard, in case the instance fails to launch successfully. Otherwise the script keeps running forever.

```

if [ -z "$INSTANCE_ID" ] && [ "$INSTANCE_STATE" != 'running' ]; then
  echo "Failed to provision instance"
  exit 1
fi

```

If the `Instance ID` cannot be retrieved or the `instance state` is not running after 30 retry attempts, the script will exit with an error status code.

Once the `Instance ID` is found and the instance is in a running state, the script attempts to attach the `EBS` volume to the `EC2` instance. It's crucial that this step happens immediately after the instance becomes available, as several `cfn-scripts` begin running right after instance creation. One of these scripts automatically creates a filesystem on the volume and mounts it to the `/var/lib/docker/volumes` directory. If the volume isn’t attached in time, this step will fail, which then fails instance creation and therefore automatic rollbacks the `CloudFormation` stack.

After retrieving the `Instance ID` the script is trying to retrieve the `Volume ID` that belongs to the volume that was created by the `EBS` `CloudFormation` template. 

```
VOLUME_ID=$(aws ec2 describe-volumes --filters "Name=tag:Name,Values='$HOST/data'" --query "Volumes[?Tags[?Value=='$EBS_STACK_ID']].VolumeId" --output text $ACCOUNT_PROFILE 2>/dev/null)
```

Once the `Volume ID` is found, the system attempts to attach the volume using the following command. 
The command includes the configured `device name` from the previous step, the `Instance ID` to which the volume will be attached, and the ID of the volume itself.

```
VOLUME=$(aws ec2 attach-volume --device $DEVICE_NAME --instance-id $INSTANCE_ID --volume-id $VOLUME_ID --output text $ACCOUNT_PROFILE 2>/dev/null)
```

Rightafter, the status of the volume will be retrieved to check if the volume is attached successfully. When this is not the case, the script waits for 30 seconds before retrying.

```

while [[ "$STATUS" == 'attaching' ]]; do
    echo "Volume is still attaching .. Sleeping 30 seconds"
    sleep 30
    STATUS=$(aws ec2 describe-volumes --filters "Name=tag:Name,Values='$HOST/data'" --query "Volumes[?Tags[?Value=='$EBS_STACK_ID']].Attachments[].State" --output text $ACCOUNT_PROFILE 2>/dev/null)
done

```

When the status of the volume is `ATTACHED` the volume is attached succesfully to the instance. Otherwise attaching the volume failed and the script will exit with an error status code.

```

if [ "$STATUS" != 'attached' ]; then
    echo "Volume attaching failed with status $STATUS"
    exit 1
else
    echo "Volume attaching is complete"
fi


```

After the `EBS` volume is successfully attached to the `EC2` instance, the script waits for all `cfn-scripts` to complete execution on the instance. These scripts handle several tasks, including creating a filesystem on the attached volume and mounting it to `Docker's` default directory at `/var/lib/docker/volumes`. Additionally, the script update the `/etc/fstab` file to ensure that the volume is automatically mounted on reboot using the device's `UUID` instead of the device name. This approach also prevents issues when attaching the same volume to an other `EC2` instance.

```
prepare_volume:
  commands:
    01_mount_volume:
      command: !Sub |
        if [ -n "${SnapshotId}" ]; then
          sudo mount "${EBSDeviceName}" /var/lib/docker/volumes
        else
          sudo mkfs -t xfs "${EBSDeviceName}"
          sudo mount "${EBSDeviceName}" /var/lib/docker/volumes
        fi
    02_configure_fstab:
        command: !Sub |
          UUID=$(sudo blkid -o value -s UUID "${EBSDeviceName}")
          if [ -n $UUID ]; then
            sudo cp /etc/fstab /etc/fstab.orig
            sudo echo "UUID=$UUID /var/lib/docker/volumes xfs defaults,nofail 0 2" >> /etc/fstab
          else
            echo "Failed to create /etc/fstab entry. UUID is not found"
            exit 1
          fi
```

#### 2.1.3. CloudFormation Template

The `CloudFormation` template for creating the `EBS` volume looks like this:

```

AWSTemplateFormatVersion: '2010-09-09'
Description: 'Creates an EBS Volume for storing the IoT data.'
Parameters:
  Host:
    Description: The hostname of the machine where this volume is being attached.
    Type: String
  AvailabilityZone:
    Description: The AZ where the EBS volume needs to be created.
    Type: String
  DiskSize:
    Description: Amount of storage you want to provision for this EBS volume.
    Type: Number
    Default: 16
  SnapshotId:
    Description: Snapshot ID to create the EBS volume based of an existing Snapshot.
    Type: String
    Default: ""

Conditions:
  IsSnapshotProvided: !Not [!Equals [!Ref SnapshotId, ""]]

Resources:
  ORDataVolume:
    Type: AWS::EC2::Volume
    Properties:
      AvailabilityZone: !Ref AvailabilityZone
      Size: !Ref DiskSize
      VolumeType: gp3
      SnapshotId: !If [IsSnapshotProvided, !Ref SnapshotId, !Ref 'AWS::NoValue']
      Tags:
        - Key: Name
          Value: !Sub ${Host}/data
  
```

The script will create a `EBS` volume based on the parameters that are passed from the `provision host` script. To recognise every volume easily there will be a tag added with the name of the host.
If the condition `IsSnapshotProvided` is true, when there is a value passed, the `Snapshot ID` will be configured otherwise this parameter remains empty.

### 2.2. Adding CloudWatch metrics/alarms for the EBS data volume

#### 2.2.1. CloudFormation Template
To monitor the performance and health of the `EBS` volume, I added `CloudWatch` metrics and alarms for this device. 

As part of the `cfn-scripts` the `Cloudwatch Agent` will be configured to retrieve several metrics from the `EC2` machine such as the CPU utilization, amount of memory that is used, disk usage etc. The script looks like this:

```
                  {
                    "agent":{
                      "metrics_collection_interval": 300
                    },
                    "metrics": {
                      "append_dimensions": {
                        "InstanceId": "${aws:InstanceId}"
                      },
                      "metrics_collected": {
                        "mem": {
                          "measurement": [
                            "mem_used_percent"
                          ],
                          "metrics_collection_interval": 900
                        },
                        "disk": {
                          "drop_device": true,
                          "measurement": [
                            "used_percent"
                          ],
                          "resources": [
                            "/",
                            "/var/lib/docker/volumes"
                          ],
                          "metrics_collection_interval": 900
                        }
                      }
                    },
                    "logs": {
                      "metrics_collected": {
                        "prometheus": {
                          "log_group_name": "Prometheus",
                          "prometheus_config_path": "/opt/aws/amazon-cloudwatch-agent/var/prometheus.yaml",
                          "emf_processor": {
                            "metric_declaration_dedup": true,
                            "metric_namespace": "CWAgent-Prometheus",
                            "metric_unit": {
                              "artemis_message_count": "Count",
                              "artemis_messages_added": "Count",
                              "or_rules_seconds_max": "Seconds",
                              "or_rules_seconds_sum": "Seconds",
                              "or_rules_seconds_count": "Count",
                              "or_attributes_seconds_max": "Seconds",
                              "or_attributes_seconds_sum": "Seconds",
                              "or_attributes_seconds_count": "Count",
                              "or_attributes_total": "Count",
                              "or_provisioning_seconds_max": "Seconds",
                              "or_provisioning_seconds_sum": "Seconds",
                              "or_provisioning_seconds_count": "Count",
                              "executor_pool_size_threads": "Count",
                              "executor_pool_core_threads": "Count",
                              "executor_pool_max_threads": "Count",
                              "executor_seconds_count": "Count",
                              "executor_seconds_sum": "Seconds",
                              "haproxy_server_current_sessions": "Count",
                              "haproxy_server_bytes_in_total": "Bytes",
                              "haproxy_server_bytes_out_total": "Bytes",
                              "haproxy_server_status": "Count",
                              "haproxy_server_http_responses_total": "Count",
                              "haproxy_server_max_session_rate": "Count/Second",
                              "haproxy_server_total_time_average_seconds": "Seconds"
                            },
                            "metric_declaration": [
                              {
                                "source_labels": [ "job" ],
                                "label_matcher": "^manager$",
                                "dimensions": [
                                  [ "InstanceName" ]
                                ],
                                "metric_selectors": [
                                  "^or_rules_seconds_count$",
                                  "^or_rules_seconds_sum$",
                                  "^or_rules_seconds_max$",
                                  "^or_attributes_seconds_count$",
                                  "^or_attributes_seconds_sum$",
                                  "^or_attributes_seconds_max$",
                                  "^or_provisioning_seconds_count$",
                                  "^or_provisioning_seconds_sum$",
                                  "^or_provisioning_seconds_max$"
                                ]
                              },
                              {
                                "source_labels": [ "job", "source" ],
                                "label_matcher": "manager;(RulesEngine|AgentService|DefaultMQTTHandler|AssetResource|WebsocketClient)",
                                "dimensions": [
                                  [ "InstanceName", "source" ]
                                ],
                                "metric_selectors": [
                                  "^or_attributes_total$"
                                ]
                              },
                              {
                                "source_labels": [ "job", "name" ],
                                "label_matcher": "^manager;ContainerExecutor$",
                                "dimensions": [
                                  [ "InstanceName","name" ]
                                ],
                                "metric_selectors": [
                                  "^executor_pool_",
                                  "^executor_seconds_count$",
                                  "^executor_seconds_sum$"
                                ]
                              },
                              {
                                "source_labels": [ "job" ],
                                "label_matcher": "^manager$",
                                "dimensions": [
                                  [ "InstanceName","queue" ]
                                ],
                                "metric_selectors": [
                                  "^artemis_message_count$",
                                  "^artemis_messages_added$"
                                ]
                              },
                              {
                                "source_labels": [ "job" ],
                                "label_matcher": "^proxy$",
                                "dimensions": [
                                  [ "InstanceName", "proxy", "server" ]
                                ],
                                "metric_selectors": [
                                  "^haproxy_server_total_time_average_seconds$",
                                  "^haproxy_server_max_session_rate$",
                                  "^haproxy_server_bytes",
                                  "^haproxy_server_current_sessions$"
                                ]
                              },
                              {
                                "source_labels": [ "job" ],
                                "label_matcher": "^proxy$",
                                "dimensions": [
                                  [ "InstanceName", "proxy", "server", "code" ]
                                ],
                                "metric_selectors": [
                                  "^haproxy_server_http_responses_total$"
                                ]
                              },
                              {
                                "source_labels": [ "job" ],
                                "label_matcher": "^proxy$",
                                "dimensions": [
                                  [ "InstanceName", "proxy", "server", "state" ]
                                ],
                                "metric_selectors": [
                                  "^haproxy_server_status$"
                                ]
                              }
                            ]
                          }
                        }
                      }
                    }
                  }

```

To add metrics for the amount of disk usage that is currently in use, I added the mountpoint for the new `EBS` volume to the `resources` block. 
This ensures that metrics for this mountpoint are retrieved by the `Cloudwatch Agent`

```

"drop_device": true,
"measurement": [
  "used_percent"
],
"resources": [
  "/",
  "/var/lib/docker/volumes"
],

```

After that, I added a new `CloudWatch Alarm` to the same `CloudFormation` template. This alarm is configured to trigger if disk usage exceeds 90% within a one-hour period. When the alarm is triggered, Amazon sends a notification to the configured `SNS` topic, which in turn sends an email alert to the topic's subscribers.
To connect the newly added metric to this alarm, I have configured the `Dimensions` block with the required details such as the `Instance ID`, the path that is referring to the mountpoint within the metrics and the `Volume Type`.

```

  DataDiskUtilizationAlarm:
    Type: AWS::CloudWatch::Alarm
    Condition: MetricsEnabled
    Properties:
      Namespace: CWAgent
      MetricName: disk_used_percent
      Statistic: Average
      Period: 3600
      EvaluationPeriods: 1
      ComparisonOperator: GreaterThanThreshold
      Threshold: 90
      AlarmActions:
        - !Ref SnsTopic
      OKActions:
        - !Ref SnsTopic
      Dimensions:
        - Name: InstanceId
          Value: !Ref EC2Instance
        - Name: path
          Value: /var/lib/docker/volumes
        - Name: fstype
          Value: xfs

```

### 2.3. Adding support for automatic snapshot creation of the EBS data volume

#### 2.3.1. Provision Host Script
To ensure that the data on the `EBS` volume is securely backed up, the `provision host` script creates an `Amazon Data Lifecycle Manager (DLM)` policy for automatic snapshot creation. This policy ensures that snapshots of the `EBS` volume are created automatically at regular intervals.
To maintain consistency throughout the script, I implemented this feature in the same way as the `EBS` volume creation.

I started by setting the `DLM_STACK_NAME` variable to generate an unique `CloudFormation` stack name for this feature.

```
DLM_STACK_NAME="$STACK_NAME-dlm-ebs-snapshot-policy"
```

After that, the script will check if the `CloudFormation` stack for the `DLM` policy already exists, if some, the `STACK_ID` variable will be set for future reference and the script will continue with the next steps.

```

if [ -n "$STATUS" ] && [ "$STATUS" != 'DELETE_COMPLETE' ]; then
  echo "Stack already exists for this host '$HOST' current status is '$STATUS'"
  STACK_ID=$(aws cloudformation describe-stacks --stack-name $DLM_STACK_NAME --query "Stacks[0].StackId" --output text 2>/dev/null)
else

```

When the `CloudFormation` stack is not created for this feature, the script will trying to create them by first searching for the `CloudFormation` template within the specified directories.
If the `CloudFormation` template cannot be found, the system wil exit with an error status code, Otherwise the stack creation process will continue.

```

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

```

Before the stack can be created the script first checks if the required `IAM` role is already created in the AWS account. The `IAM` role is required for the `DLM` policy to execute the snapshot creation tasks on behalf of the `IAM` user.
If the role doesn't exists yet, the system will create the default role and sets the `ROLE_ARN` variable with the `Amazon Resource Name`. This variable will be passed to the `CloudFormation` template in the next step.

```

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


```

After configuring the `ROLE_ARN` variable, the script sets the necessary variables for the `CloudFormation` script. The `DLM_DESCRIPTION` variable is created by combining the `$HOST` value while removing any periods, as they are not allowed in the description. Additionally, the `ROLE_ARN` retrieved in the previous step is set, along with the `EBS_STACK_ID`, which identifies the volume that the policy should target.

```

DLM_DESCRIPTION="OpenRemote-${HOST%.*}"
PARAMS="ParameterKey=PolicyDescription,ParameterValue='$DLM_DESCRIPTION'"
PARAMS="$PARAMS ParameterKey=DLMExecutionRoleArn,ParameterValue='$ROLE_ARN'"
PARAMS="$PARAMS ParameterKey=EBSStackId,ParameterValue='$EBS_STACK_ID'"

```

Once the parameters are configured, the script attempts to create the `CloudFormation` stack. If the stack creation fails, the script exits with an error code and stops execution.

```
STACK_ID=$(aws cloudformation create-stack --capabilities CAPABILITY_NAMED_IAM --stack-name $DLM_STACK_NAME --template-body file://$DLM_TEMPLATE_PATH --parameters $PARAMS --output text)

if [ $? -ne 0 ]; then
  echo "Create stack failed"
  exit 1
fi
```

After the `CloudFormation` stack is successfully created, the script checks its status every 30 seconds. If the status returns `CREATE_COMPLETE`, the stack was created successfully, and the script proceeds to the next steps. However, if the status is neither `CREATE_IN_PROGRESS` nor `CREATE_COMPLETE`, it likely indicates an error, and the script will exit with an error code and stop execution.

```

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

```

#### 2.3.2. CloudFormation Template

The `CloudFormation` template for creating the `DLM` policy looks like this:

```

Parameters:
  PolicyDescription:
    Description: Lifecycle Policy Description
    Type: String
  DLMExecutionRoleArn:
    Description: Role ARN for executing the DLM operations.
    Type: String
  EBSStackId:
    Description: EBS StackId of the volume that need to be targeted by this policy.
    Type: String

Resources:
  EBSPolicy:
    Type: AWS::DLM::LifecyclePolicy
    Properties:
      Description: !Ref PolicyDescription
      ExecutionRoleArn: !Ref DLMExecutionRoleArn
      State: ENABLED
      PolicyDetails:
        PolicyLanguage: STANDARD
        PolicyType: EBS_SNAPSHOT_MANAGEMENT
        TargetTags:
          - Key: aws:cloudformation:stack-id
            Value: !Ref EBSStackId
        ResourceTypes: 
          - VOLUME
        Schedules:
          - Name: Daily Backup
            CreateRule:
              Interval: 24
              IntervalUnit: HOURS
              Times:
              - '05:00'
            RetainRule:
              Count: 5

```

The script creates a `lifecycle policy` with a single schedule that triggers a new snapshot every 24 hours at 5 AM. The `RetainRule` is configured to keep the most recent 5 snapshots, automatically deleting older ones beyond that limit. 
The policy is enabled immediately upon creation.
To ensure that snapshots are only created for the correct volume, the `TargetTags` parameter uses the `EBS_STACK_ID` value to identify the appropriate volume.