<!-- title: Decomposition CI/CD pipeline -->

## Decomposition CI/CD pipeline  <!-- omit in toc -->

## Context
This document provides an overview of the flowcharts I created to decomposite the`CI/CD` workflow. By visualizing this into a flowchart I've got a better understanding how the `CI/CD` workflow is functioning.

## Contents <!-- omit in toc -->

<div class="toc">

- [Context](#context)
- [1. Flowchart: Provision Account](#1-flowchart-provision-account)
- [2. Flowchart: Provision Host](#2-flowchart-provision-host)

</div>

## 1. Flowchart: Provision Account

The picture below visualizes the working of the `provision account` bash script. The bash script will be executed when the `provision account` workflow get triggered by a manual `workflow dispatch`.
This script creates an AWS account for the customer within the AWS account from OpenRemote using AWS `Organizations`. After the account is created the script will provision and configure several components such as the `VPC`, `SSH Key`, `CloudWatch` Dashboards and `Route53` for domain management.

<img src="./Media/provision_account_script.png" width="1000">

## 2. Flowchart: Provision Host

The picture below visualizes the working of the `provision host` bash script. The bash script will be executed when the `provision host` workflow get triggered by a manual `workflow dispatch`
This script provisions an `EC2` instance within the customers AWS account. The instance will be used for running OpenRemote on AWS.

<img src="./Media/provision_host_script.png" width="1000">