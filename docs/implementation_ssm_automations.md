<!-- title: Implementation: SSM Automations -->

## Implementation: SSM Automations  <!-- omit in toc -->

## Context
This document provides a detailed overview how I implemented the automations on the `AWS` platform using `Amazon Systems Manager` (`SSM`)
It also outlines the decisions I made and the challenges encountered throughout the development process.

<div style="page-break-after: always;"></div>

## Contents <!-- omit in toc -->

<div class="toc">

</div>

<div style="page-break-after: always;"></div>

## 1. Research based on feedback
After several iterations on the `EBS` data volume implementation, it is now nearly production-ready.
I've got one last comment to investigate if it's possible to create an automation to replace an existing `EBS` data volume with an snapshot.

### 1.1. Investigating SSM Automations
Currently, If an OpenRemote version update fails, we manually rollback the update by replacing the `root` volume with the latest snapshot. This manual process introduces downtime and takes a lot of time.

By automating this process, we can rollback much quicker which results in less downtime and on top of that we can update more frequently.

<img src="./Media/review_15.png" width="1000">

I already created some `SSM` documents for `attaching`, `detaching`, `mounting` and `umounting` the `EBS` data volume. Those documents are used for preparing the `EBS` data volume when provisioning the `EC2` instance for the host.

Despite the fact that these documents are working as expected, I'm not happy in the way the work. These (command) documents are interacting with the AWS API via `CLI` commands in `bash`. Unfortunately, they are executed asynchronously and don't wait for other commands before continuing. As a result of this, I need to implement several loops within the script to wait for a specific status before marking the execution of the command as `success`. I think this approach is to much error prone and not reliable enough to be used in an production environment.

To address this issue, I did some more extensive research on how `Amazon Systems Manager` (`SSM`) is working and which features it offers. 

I came across `SSM Automation`, a tool for automating deployment, maintenance and remediation tasks for a variety of AWS Services.
After exploring the documentation I found out that with these type of documents it is possible to interact with the AWS API natively using the action `aws:executeAwsApi`. With the action `aws:waitForAwsResourceProperty` you can wait for a variable to become a specific value, for example a `success` status. These automations are not executed asynchrously and wait for each other to complete with an `success` status before continuing. You can even control the next step that is being executed by providing the step name in the `nextStep` property.

This is exactly what we need, all the issues we have with normal `SSM` documents are solved by using `SSM` automations. Since this approach suites the best for our use case, I decided to give it a try by first rewriting the existing documents using `SSM` automation.

## 2. Rewriting existing SSM documents using SSM automation

## 2.1. Attach volume
I started by rewriting the attach volume document, this is one of the documents that has the issues that `SSM` automation can solve.
The first part of the `SSM` automation documents look almost the same as the `command` documents. Except for the `DocumentType` and `schemaVersion` parameters, `SSM` automation uses `schemaVersion` `0.3` instead of `2.2`. The `DocumentType` must be set to `Automation`

```
  SSMAttachVolumeDocument:
    Type: AWS::SSM::Document
    Properties:
      DocumentType: Automation
      DocumentFormat: YAML
      TargetType: /AWS::EC2::Instance
      Name: attach_volume
      Content:
        schemaVersion: '0.3'
        description: 'Script for attaching an EBS data volume'
        parameters:
          VolumeId:
            type: String
            description: '(Required) Specify the VolumeId of the volume that should be attached'
            allowedPattern: '^vol-[a-z0-9]{8,17}$'
          InstanceId:
            type: String
            description: '(Required) Specify the InstanceId of the instance where the volume should be attached'
            allowedPattern: '^i-[a-z0-9]{8,17}$'
          DeviceName:
            type: String
            description: '(Required) Specify the Device name where the volume should be mounted on'
            allowedPattern: '^/dev/sd[b-z]$'
```

The parameters are described the exact same way, no changes need to be made here.
This document have 3 different parameters:

- `VolumeId`: The `EBS` data volume that needs to be attached to the instance.
- `InstanceId`: The `EC2` instance where the `EBS` data volume needs to be attached.
- `DeviceName`: The `DeviceName` where the volume needs to be mounted on.

After the initial configuration, I started describing the different steps that need to be excuted in the `mainSteps` block. Instead of using the `aws:runShellScript` action and specify the commands in `bash` that are being executed on the targeted `EC2` machine, I specify the different AWS `API` actions by using the `aws:executeAwsApi` action.

### 2.1.1. Get Instance Details
The first step is to retrieve the `EC2` instance details using the `InstanceId` that is specified in the `parameters` section. This is handeled by the `DescribeInstances` API.

When the instance details are fetched, The `hostname` is retrieved by filtering the `tags` property and searching for the tag with the `Key==Name` . This value is pushed to the `outputs` section so it becomes available for the next steps.
The `hostname` variable is very important in this process as it is used in different places to reference the various `AWS` components, for example, to target the correct volume in the `DLM` policy for creating `snapshots`.

```
# Retrieve instance details to get the Host name.
- name: GetInstanceDetails
  action: aws:executeAwsApi
  timeoutSeconds: 120
  onFailure: Abort
  inputs:
   Service: ec2
   Api: DescribeInstances
   InstanceIds:
    - '{{ InstanceId }}'
  outputs:
    - Name: Host
      Selector: $.Reservations[0].Instances[0].Tags[?(@.Key == 'Name')].Value
      Type: String
   nextStep: AttachVolume
```
After this step is successfully executed, the automation will continue by executing the step provided in the `nextStep` parameter. In this case the `AttachVolume` step.

### 2.1.2. Attach Volume
After successfully retrieving the instance details, we can start attaching the `EBS` data volume.
