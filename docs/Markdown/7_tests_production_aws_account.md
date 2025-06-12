---
title: "AWS Production Account"
subtitle: "Tests"
author: [Dennis Catharina Johannes Kuijs]
date: "June 17, 2025"
lang: "en"
toc: true
toc-own-page: true
titlepage: true
titlepage-text-color: "FFFFFF"
titlepage-rule-color: "360049"
titlepage-rule-height: 0
titlepage-background: "config/document_background.pdf"
titlepage-logo: "config/logo.png"
logo-width: 35mm
footer-left: "OpenRemote"
footer-center: "\\theauthor"
code-block-font-size: "\\scriptsize"
...

# 1. Context
This document provides a detailed description how I tested my `EBS` data volume implementation on OpenRemote's AWS account.

# 2. Configure AWS account
Before running the `CI/CD` workflow, I configured the `AWS` account with the required `IAM` policies and provisioned/updated several `CloudFormation` stacks.

## 2.1. Provisioning / Updating CloudFormation Stacks
First, I provisioned the `or-ssm` CloudFormation stack to ensure the `SSM` documents are available in `Amazon Systems Manager (SSM)`. When an new AWS account is provisioned using the `provision_account` workflow, these documents are automatically created during workflow execution. In this case the AWS account was already created. Therefore, I need to add these documents manually to ensure the workflow can execute them to attach/mount the `EBS` data volume to the instance.

![The CloudFormation Stack or-ssm has been provisioned successfully](../Media/aws_or_ssm_created.png)

I also updated the existing `or-dashboard-default` `CloudFormation` stack to make the `EBS` data volume visible on the `CloudWatch` Dashboard.

![The CloudFormation Stack for the CloudWatch Dashboard has been updated successfully](../Media/aws_or_dashboard_default_updated.png)
![The CloudWatch Dashboard where the EBS data volume is shown](../Media/aws_or_dashboard_default.png)

## 2.2. Updating IAM Roles
In the `CI/CD` workflow, I've added the feature to create an `DLM` policy for automatic snapshot creation. Before this can be provisioned, the `IAM` role that's assumed by the `CI/CD` runner needs to have the approriate permissions.
I added the following permissions to the `developers-access-eu-west-1` role:

- `DLMPolicy (Inline)`
  - `dlm:CreateLifecyclePolicy` - To create the Amazon Data Lifecycle Manager policy for automatic snapshot creation.
  - `dlm:TagResource` - To tag the resources (volumes) that needs to be targeted by the `DLM` policy.
- `IAMPassRole (Inline)`
  - `arn:aws:iam::xxxxx:role/developers-access-eu-west-1` - To be able to pass this `IAM` role to the `DLM` service.
- `AWSDataLifecycleManagerServiceRole (Policy)` - To give `DLM` permissions to take actions on AWS resources, for example to create snapshots from the `EBS` data volume on behalf of the AWS user.

I also added the `DLM` service to the trusted entities to ensure `DLM` can assume this role.

![The DLM service is added to the trusted policies](../Media/aws_dlm_trusted_entities.png)

# 3. Provisioning host
After configuring the AWS account, I was be able to run the `provision_host` workflow with my changes. Since the implementation is not merged in the `master` branch, I need to use the following `GitHub` CLI command to run the workflow from an different branch:

```sh
gh workflow run "provision host" --ref feature/ebs-volume-creation --field ACCOUNT_NAME=openremote --field HOST=dennis.openremote.app
```

The workflow provisiones a new host in the `openremote` AWS account with the hostname (FQDN) `dennis.openremote.app`. The following services are provisioned:
- An `EC2` instance configured with `Docker`, `Docker-Compose`
- An `EBS` Data Volume that's mounted to the `/var/lib/docker/volumes` directory
- An `DLM` policy for automatically create snapshots from the `EBS` data volume
- Several `CloudWatch` healthchecks to monitor the performance of the `EC2` instance and the OpenRemote platform
- An `S3` bucket for storing the `PGDUMP` PostgreSQL backup file

After approximately 5 minutes, the workflow has finished execution and the host is ready to be used.

![The Provision Host CI/CD workflow has been executed successfully and provisioned the EC2 instance in the AWS account](../Media/ci_cd_provision_host_success.png)

# 4. Tests in the AWS account
After provisioning the host in the AWS account I can start testing the `EBS` volume implementation.

## 4.1. Deploying OpenRemote to the new host
When the `provision_host` workflow is successfully executed, it creates an empty `EC2` instance. Before I can test my implementation I need to deploy OpenRemote on this virtual machine.
I used the `CI/CD` workflow to deploy the branch `feature/edit-map-layers` to this instance. This takes around 10 minutes as it needs to build the `Docker` images first.

When this workflow is finished successfully, OpenRemote is running on the `EC2` instance and accessible using the hostname (`dennis.openremote.app`)

![The CI/CD workflow has been executed successfully and deployed OpenRemote to the EC2 instance](../Media/ci_ci_edit_map_layers_deployment.png)

## 4.2. Testing Detach Volume
First, I tested the option to detach the `EBS` volume by executing the `detach_volume` `SSM` document using the `volumeId`. 
After the document is successfully executed I manually checked every step to make sure the tasks are executed correctly.

![The Detach Volume SSM automation is successfully executed](../Media/ssm_detach_volume.png)

### 4.2.1. Volume is detached from the EC2 instance
The `EBS` data volume is correctly detached from the EC2 instance. Only the `root` volume is still attached. The `EBS` data volume is also not showing up in the `block devices` list anymore.

![The EBS data volume is detached from the EC2 instance](../Media/aws_ec2_ebs_data_volume_detached.png)

### 4.2.2. Volume is umounted
The `EBS` data volume is successfully umounted from the `/var/lib/docker/volumes` directory. The `docker` persistent volumes are no longer available by the filesystem.

![The EBS data volume is umounted from the file system](../Media/aws_ec2_volume_umounted.png)

### 4.2.3. Docker is successfully stopped
The `Docker` service and socket are successfully stopped. The `Docker` containers are no longer running and OpenRemote is shutdown safely.

![The Docker service and socket are successfully stopped](../Media/aws_docker_stop.png)

### 4.2.4. Entry in the File Systems Table
When the `EBS` volume is successfully detached, the system has removed the entry from the file systems table in the `/etc/fstab` file.

![The EBS data volume is removed from the File Systems Table](../Media/aws_ec2_fstab_entry_removed.png)

### 4.2.5. Volume not targeted by DLM Policy
The tag gets updated to `or-data-not-in-use` to make sure the `EBS` data volume is no longer targeted by the `DLM` policy. The policy only needs to target the `EBS` data volume that is currently attached to the instance.

![The EBS data volume is not targeted by the DLM policy anymore](../Media/aws_dlm_policy_not_targeted.png)

## 4.3. Testing Attach Volume
When the `EBS` volume is successfully detached from the `EC2` instance I start testing the possibility to attach the `EBS` volume again using the `attach_volume` `SSM` document.
After the document is successfully executed I manually go through every step to ensure it's processed correctly.

![The Attach Volume SSM automation is successfully executed](../Media/aws_ec2_ssm_attach_volume.png)

### 4.3.1. Volume is attached to the EC2 instance
The `EBS` data volume is successfully attached to the `EC2` instance.

![The EBS data volume is attached to the EC2 instance](../Media/aws_ec2_ebs_data_volume_attached.png)

### 4.3.2. Volume is mounted 
The `EBS` data volume is successfully mounted to the `/var/lib/docker/volumes` directory. 

![The EBS data volume is mounted to the Docker volumes directory](../Media/aws_ec2_volume_mounted.png)

### 4.3.3. Entry in the File Systems Table
After successfully attaching the `EBS` data volume to the `EC2` instance, the script will add the `block device` to the file systems table in the `/etc/fstab` file.

![The EBS data volume is added to the File Systems Table](../Media/aws_ec2_fstab_entry_added.png)

### 4.3.4. Volume is targeted by DLM Policy
The script has updated the tag to `or-data-in-use` to make sure the `EBS` volume is targeted by the `DLM` policy again. `DLM` will now create automatic snapshots for this volume.

![The EBS Data volume is targeted by the DLM Policy](../Media/aws_ec2_dlm_policy_targeted.png)

### 4.3.5. Docker is successfully started
The script enables the `Docker` socket and service. The existing containers are automatically trying to boot up. After a few minutes all the containers became healthy and OpenRemote is accesible.

![The Docker containers are healthy](../Media/aws_ec2_docker_start.png)

When visiting the OpenRemote platform, all the data is visible and the platform is working as expected.

![The IoT data is successfully loaded and available in the platform](../Media/aws_ec2_openremote_data_visible.png)

## 4.4. Testing Replace Volume with/without Volume Deletion
In this section, I tested the option to replace an existing `EBS` data volume with an snapshot using the `replace_volume` `SSM` document. In this example, the script is configured to keep the original `EBS` data volume.
After successfully executed the document, I checked every step manually to make sure all the tasks are executed properly.

![The Replace Volume SSM automation is successfully executed without deleting the current EBS data volume](../Media/ssm_replace_volume_without_deletion.png)

### 4.4.1. Create new volume from snapshot
The script creates an new `EBS` data volume based off an existing snapshot an attaches this volume to the `EC2` instance. The existing `EBS` data volume will be detached from the instance.

![The current EBS data volume is replaced with the new EBS data volume that is based off an existing snapshot](../Media/aws_ec2_volume_replaced.png)

### 4.4.2. Old volume detached
The current `EBS` data volume is successfully detached from the `EC2` instance and is visible in the `volumes` overview

![The current EBS data volume is detached from the EC2 instance](../Media/aws_ec2_old_volume_visible.png)

### 4.4.3. New volume mounted
The newly created `EBS` data volume is mounted to the `/var/lib/docker/volumes` directory. The snapshot data (docker volumes) are available in this directory.

![The newly created EBS data volume is mounted to the Docker volumes directory](../Media/aws_ec2_newly_ebs_volume_mounted.png)

### 4.4.4. Entry in the File Systems Table
The newly created `EBS` data volume is added to the file systems table in the `/etc/fstab` file. The old volume is removed from this table.

![The newly created EBS data volume is added to the File Systems Table](../Media/aws_ec2_fstab_newly_ebs_volume_added.png)

### 4.4.5. New volume is targeted by DLM Policy
Only the newly created `EBS` data volume is targeted by the `DLM` policy using the tag `or-data-in-use`. The tag from the old volume is updated to `or-data-not-in-use` to ensure it's no longer targeted by the `DLM` policy.

![The EBS Data volume is targeted by the DLM Policy](../Media/aws_ec2_dlm_policy_new_volume_targeted.png)

### 4.4.6. Docker is starting
The scripts starts the `Docker` service and socket. The containers are booting up again using the existing `docker` volumes from the snapshot that are mounted to the `/var/lib/docker/volumes` directory.

![The Docker containers are healthy](../Media/aws_ec2_docker_starting_snapshot_data.png)

After a few minutes, the containers are healthy and OpenRemote is accessible again. The data from the snapshot is successfully loaded.

![The IoT data is successfully loaded and available in the platform](../Media/aws_ec2_docker_data_openremote.png)

### 4.4.7. Delete original EBS data volume
When the `DeleteVolume` parameter is configured to `true` this step will be executed and the original `EBS` data volume will be deleted

![The Replace Volume SSM automation is successfully executed with the option to delete the original EBS data volume](../Media/ssm_replace_volume_with_deletion.png)

# 5. Final changes to the implementation
After completing the tests and confirming everything is working as expected, I received one final comment from a team member to review. In the `provision_host` script, I added logic to create the default `DLM` `IAM` role if it doesn't already exist in the AWS account. 
The `ARN` of this role is then passed to the parameters section of the `create-ec2` `CloudFormation` stack, ensuring the `DLM` policy has the necessary permissions to create snapshots on behalf of the user.

```sh
  # Check for DLM IAM Role
  echo "Check for DLM IAM Role"
  
  ROLE_ARN=$(aws iam get-role --role-name AWSDataLifecycleManagerDefaultRole --query "Role.Arn" --output text $ACCOUNT_PROFILE 2>/dev/null)
  if [ -z "$ROLE_ARN" ]; then
    ROLE=$(aws dlm create-default-role --resource-type snapshot --output text $ACCOUNT_PROFILE)

    if [ $? -ne 0 ]; then
      echo "IAM Role creation has failed"
      exit 1
    else
      echo "IAM Role creation is complete"
    fi

    ROLE_ARN=$(aws iam get-role --role-name AWSDataLifecycleManagerDefaultRole --query "Role.Arn" --output text $ACCOUNT_PROFILE 2>/dev/null)
  fi

  echo "DLM IAM Role found"
```

Instead of creating this role, I added the policy inside the role (`AWSDataLifecycleManagerServiceRole`) to the already existing `developers-access-eu-west-1` role. 
With this approach the check for the `DLM` `IAM` role can be removed from the `provision_host` script and the `developers-access-eu-west-1` `ARN` can be passed to the parameters section.

To make this work, I added the `DLM` service to the trusted entities in the role's trust policy, allowing it to assume the role. I also included the role's `ARN` in the inline `PassRole` policy to allow `CloudFormation` to assign this role to the `DLM` policy when provisioning the host.

# Final moment: Work is merged into the main codebase
On Thursday May 22, 2025 at 5:24 PM the `EBS` data volume implementation is merged into the `master` branch.

![The pull request is merged into the main codebase](../Media/github_work_merged_1.png)
![The pull request is merged into the main codebase](../Media/github_work_merged_2.png)