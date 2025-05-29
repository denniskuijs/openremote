<!-- title: 5. Tests: Production AWS Account -->

## 5. Tests: Production AWS Account  <!-- omit in toc -->

## Context
This document provides a detailed description how I tested my `EBS` data volume implementation on OpenRemote's AWS account.

<div style="page-break-after: always;"></div>

## Contents <!-- omit in toc -->

- [Context](#context)
- [1. Configure AWS account](#1-configure-aws-account)
  - [1.1. Provisioning / Updating CloudFormation Stacks](#11-provisioning--updating-cloudformation-stacks)
  - [1.2. Updating IAM Roles](#12-updating-iam-roles)
- [2. Provisioning host](#2-provisioning-host)
- [3. Tests in the AWS account](#3-tests-in-the-aws-account)
  - [3.1. Deploying OpenRemote to the new host](#31-deploying-openremote-to-the-new-host)
  - [3.2. Testing Detach Volume](#32-testing-detach-volume)
    - [3.2.1. Volume is detached from the EC2 instance](#321-volume-is-detached-from-the-ec2-instance)
    - [3.2.2. Volume is umounted](#322-volume-is-umounted)
    - [3.2.3. Docker is successfully stopped](#323-docker-is-successfully-stopped)
    - [3.2.4. Entry in the File Systems Table](#324-entry-in-the-file-systems-table)
    - [3.2.5. Volume not targeted by DLM Policy](#325-volume-not-targeted-by-dlm-policy)
  - [3.3. Testing Attach Volume](#33-testing-attach-volume)
    - [3.3.1. Volume is attached to the EC2 instance](#331-volume-is-attached-to-the-ec2-instance)
    - [3.3.2. Volume is mounted](#332-volume-is-mounted)
    - [3.3.3. Entry in the File Systems Table](#333-entry-in-the-file-systems-table)
    - [3.3.4. Volume is targeted by DLM Policy](#334-volume-is-targeted-by-dlm-policy)
    - [3.3.5. Docker is successfully started](#335-docker-is-successfully-started)
  - [3.4. Testing Replace Volume with/without Volume Deletion](#34-testing-replace-volume-withwithout-volume-deletion)
    - [3.4.1. Create new volume from snapshot](#341-create-new-volume-from-snapshot)
    - [3.4.2. Old volume detached](#342-old-volume-detached)
    - [3.4.3. New volume mounted](#343-new-volume-mounted)
    - [3.4.4. Entry in the File Systems Table](#344-entry-in-the-file-systems-table)
    - [3.4.5. New volume is targeted by DLM Policy](#345-new-volume-is-targeted-by-dlm-policy)
    - [3.4.6. Docker is starting](#346-docker-is-starting)

<div style="page-break-after: always;"></div>

## 1. Configure AWS account
Before running the `CI/CD` workflow, I configured the `AWS` account with the required `IAM` policies and provisioned/updated several `CloudFormation` stacks.

### 1.1. Provisioning / Updating CloudFormation Stacks
First, I provisioned the `or-ssm` CloudFormation stack to ensure the `SSM` documents are available in `Amazon Systems Manager (SSM)`. When an new AWS account is provisioned using the `provision_account` workflow, these documents are automatically created during workflow execution. In this case the AWS account was already created. Therefore, I need to add these documents manually to ensure the workflow can execute them to attach/mount the `EBS` data volume to the instance.

<img src="./Media/aws_or_ssm_created.png" width="1000">

I also updated the existing `or-dashboard-default` `CloudFormation` stack to make the `EBS` data volume visible on the `CloudWatch` Dashboard.

<img src="./Media/aws_or_dashboard_default_updated.png" width="1000"> \
<img src="./Media/aws_or_dashboard_default.png" width="1000">

### 1.2. Updating IAM Roles
In the `CI/CD` workflow, I've added the feature to create an `DLM` policy for automatic snapshot creation. Before this can be provisioned, the `IAM` role that's assumed by the `CI/CD` runner needs to have the approriate permissions.
I added the following permissions to the `developers-access-eu-west-1` role:

- `DLMPolicy (Inline)`
  - `dlm:CreateLifecyclePolicy` - To create the Amazon Data Lifecycle Manager policy for automatic snapshot creation.
  - `dlm:TagResource` - To tag the resources (volumes) that needs to be targeted by the `DLM` policy.
- `IAMPassRole (Inline)`
  - `arn:aws:iam::xxxxx:role/developers-access-eu-west-1` - To be able to pass this `IAM` role to the `DLM` service.
- `AWSDataLifecycleManagerServiceRole (Policy)` - To give `DLM` permissions to take actions on AWS resources, for example to create snapshots from the `EBS` data volume on behalf of the AWS user.

I also added the `DLM` service to the trusted entities to ensure `DLM` can assume this role.

<img src="./Media/aws_dlm_trusted_entities.png" width="1000">

## 2. Provisioning host
After configuring the AWS account, I was be able to run the `provision_host` workflow with my changes. Since the implementation is not merged in the `master` branch, I need to use the following `GitHub` CLI command to run the workflow from an different branch:

```
gh workflow run "provision host" --ref feature/ebs-volume-creation --field ACCOUNT_NAME=openremote --field HOST=dennis.openremote.app
```

The workflow provisiones a new host in the `openremote` AWS account with the hostname (FQDN) `dennis.openremote.app`. The following services are provisioned:
- An `EC2` instance configured with `Docker`, `Docker-Compose`
- An `EBS` Data Volume that's mounted to the `/var/lib/docker/volumes` directory
- An `DLM` policy for automatically create snapshots from the `EBS` data volume
- Several `CloudWatch` healthchecks to monitor the performance of the `EC2` instance and the OpenRemote platform
- An `S3` bucket for storing the `PGDUMP` PostgreSQL backup file

After approximately 5 minutes, the workflow has finished execution and the host is ready to be used.

<img src="./Media/ci_cd_provision_host_success.png" width="1000">

## 3. Tests in the AWS account
After provisioning the host in the AWS account I can start testing the `EBS` volume implementation.

### 3.1. Deploying OpenRemote to the new host
When the `provision_host` workflow is successfully executed, it creates an empty `EC2` instance. Before I can test my implementation I need to deploy OpenRemote on this virtual machine.
I used the `CI/CD` workflow to deploy the branch `feature/edit-map-layers` to this instance. This takes around 10 minutes as it needs to build the `Docker` images first.

When this workflow is finished successfully, OpenRemote is running on the `EC2` instance and accessible using the hostname (`dennis.openremote.app`)

<img src="./Media/ci_ci_edit_map_layers_deployment.png" width="1000">

### 3.2. Testing Detach Volume
First, I tested the option to detach the `EBS` volume by executing the `detach_volume` `SSM` document using the `volumeId`. 
After the document is successfully executed I manually checked every step to make sure the tasks are executed correctly.

<img src="./Media/ssm_detach_volume.png" width="1000">

#### 3.2.1. Volume is detached from the EC2 instance
The `EBS` data volume is correctly detached from the EC2 instance. Only the `root` volume is still attached. The `EBS` data volume is also not showing up in the `block devices` list anymore.

<img src="./Media/aws_ec2_ebs_data_volume_detached.png" width="1000">

#### 3.2.2. Volume is umounted
The `EBS` data volume is successfully umounted from the `/var/lib/docker/volumes` directory. The `docker` persistent volumes are no longer available by the filesystem.

<img src="./Media/aws_ec2_volume_umounted.png" width="1000">

#### 3.2.3. Docker is successfully stopped
The `Docker` service and socket are successfully stopped. The `Docker` containers are no longer running and OpenRemote is shutdown safely.

<img src="./Media/aws_docker_stop.png" width="1000">

#### 3.2.4. Entry in the File Systems Table
When the `EBS` volume is successfully detached, the system has removed the entry from the file systems table in the `/etc/fstab` file.

<img src="./Media/aws_ec2_fstab_entry_removed.png" width="1000">

#### 3.2.5. Volume not targeted by DLM Policy
The tag gets updated to `or-data-not-in-use` to make sure the `EBS` data volume is no longer targeted by the `DLM` policy. The policy only needs to target the `EBS` data volume that is currently attached to the instance.

<img src="./Media/aws_dlm_policy_not_targeted.png" width="1000">

### 3.3. Testing Attach Volume
When the `EBS` volume is successfully detached from the `EC2` instance I start testing the possibility to attach the `EBS` volume again using the `attach_volume` `SSM` document.
After the document is successfully executed I manually go through every step to ensure it's processed correctly.

<img src="./Media/aws_ec2_ssm_attach_volume.png" width="1000">

#### 3.3.1. Volume is attached to the EC2 instance
The `EBS` data volume is successfully attached to the `EC2` instance.

<img src="./Media/aws_ec2_ebs_data_volume_attached.png" width="1000">

#### 3.3.2. Volume is mounted 
The `EBS` data volume is successfully mounted to the `/var/lib/docker/volumes` directory. 

<img src="./Media/aws_ec2_volume_mounted.png" width="1000">

#### 3.3.3. Entry in the File Systems Table
After successfully attaching the `EBS` data volume to the `EC2` instance, the script will add the `block device` to the file systems table in the `/etc/fstab` file.

<img src="./Media/aws_ec2_fstab_entry_added.png" width="1000">

#### 3.3.4. Volume is targeted by DLM Policy
The script has updated the tag to `or-data-in-use` to make sure the `EBS` volume is targeted by the `DLM` policy again. `DLM` will now create automatic snapshots for this volume.

<img src="./Media/aws_ec2_dlm_policy_targeted.png" width="1000">

#### 3.3.5. Docker is successfully started
The script enables the `Docker` socket and service. The existing containers are automatically trying to boot up. After a few minutes all the containers became healthy and OpenRemote is accesible.

<img src="./Media/aws_ec2_docker_start.png" width="1000">

When visiting the OpenRemote platform, all the data is visible and the platform is working as expected.

<img src="./Media/aws_ec2_openremote_data_visible.png" width="1000">

### 3.4. Testing Replace Volume with/without Volume Deletion
In this section, I tested the option to replace an existing `EBS` data volume with an snapshot using the `replace_volume` `SSM` document. In this example, the script is configured to keep the original `EBS` data volume.
After successfully executed the document, I checked every step manually to make sure all the tasks are executed properly.

<img src="./Media/ssm_replace_volume_without_deletion.png" width="1000">

#### 3.4.1. Create new volume from snapshot
The script creates an new `EBS` data volume based off an existing snapshot an attaches this volume to the `EC2` instance. The existing `EBS` data volume will be detached from the instance.

<img src="./Media/aws_ec2_volume_replaced.png" width="1000">

#### 3.4.2. Old volume detached
The current `EBS` data volume is successfully detached from the `EC2` instance and is visible in the `volumes` overview

<img src="./Media/aws_ec2_old_volume_visible.png" width="1000">

#### 3.4.3. New volume mounted
The newly created `EBS` data volume is mounted to the `/var/lib/docker/volumes` directory. The snapshot data (docker volumes) are available in this directory.

<img src="./Media/aws_ec2_newly_ebs_volume_mounted.png" width="1000">

#### 3.4.4. Entry in the File Systems Table
The newly created `EBS` data volume is added to the file systems table in the `/etc/fstab` file. The old volume is removed from this table.

<img src="./Media/aws_ec2_fstab_newly_ebs_volume_added.png" width="1000">

#### 3.4.5. New volume is targeted by DLM Policy
Only the newly created `EBS` data volume is targeted by the `DLM` policy using the tag `or-data-in-use`. The tag from the old volume is updated to `or-data-not-in-use` to ensure it's no longer targeted by the `DLM` policy.

<img src="./Media/aws_ec2_dlm_policy_new_volume_targeted.png" width="1000">

#### 3.4.6. Docker is starting
The scripts starts the `Docker` service and socket. The containers are booting up again using the existing `docker` volumes from the snapshot that are mounted to the `/var/lib/docker/volumes` directory.

<img src="./Media/aws_ec2_docker_starting_snapshot_data.png" width="1000">

After a few minutes, the containers are healthy and OpenRemote is accessible again. The data from the snapshot is successfully loaded.

<img src="./Media/aws_ec2_docker_data_openremote.png" width="1000">
