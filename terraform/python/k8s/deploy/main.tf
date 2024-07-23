# ------------------------------------------------------------------------
# Copyright 2023 Amazon.com, Inc. or its affiliates. All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License").
# You may not use this file except in compliance with the License.
# A copy of the License is located at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# or in the "license" file accompanying this file. This file is distributed
# on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either
# express or implied. See the License for the specific language governing
# permissions and limitations under the License.
# -------------------------------------------------------------------------

resource "null_resource" "deploy" {
  connection {
    type        = "ssh"
    user        = var.user
    private_key = var.ssh_key
    host        = var.host
  }

  provisioner "remote-exec" {
    inline = [
      <<-EOF

      # Make the Terraform fail if any step throws an error
      set -e

      # Ensure environment is clean
      echo "LOG: Rerunning cleanup commands in case of cleanup failure in previous run"
      helm uninstall --debug --namespace amazon-cloudwatch amazon-cloudwatch-operator --ignore-not-found
      kubectl delete namespace python-sample-app-namespace --ignore-not-found=true
      [ ! -e helm-charts ] || sudo rm -r helm-charts
      [ ! -e python-frontend-service-depl.yaml ] || rm python-frontend-service-depl.yaml
      [ ! -e python-remote-service-depl.yaml ] || rm python-remote-service-depl.yaml

      # Clone and install operator onto cluster
      echo "LOG: Cloning helm charts repo"
      git clone https://github.com/aws-observability/helm-charts.git -q
      cd helm-charts/charts/amazon-cloudwatch-observability
      git reset --hard e0e99c77f69ef388b0ffce769371f7c735a776e4

      echo "LOG: Installing CloudWatch Agent Operator using Helm"
      helm upgrade --install --debug --namespace amazon-cloudwatch amazon-cloudwatch-operator ./ --create-namespace --set region=${var.aws_region} --set clusterName=k8s-cluster-${var.test_id}

      # Wait for pods to exist before checking if they're ready
      sleep 60
      kubectl wait --for=condition=Ready pods --all --selector=app.kubernetes.io/name=amazon-cloudwatch-observability -n amazon-cloudwatch --timeout=60s
      kubectl wait --for=condition=Ready pods --all --selector=app.kubernetes.io/name=cloudwatch-agent -n amazon-cloudwatch --timeout=60s

      if [ "${var.repository}" = "amazon-cloudwatch-agent" ]; then
        RELEASE_TESTING_SECRET_NAME=release-testing-ecr-secret
        RELEASE_TESTING_TOKEN=`aws ecr --region=us-west-2 get-authorization-token --output text --query authorizationData[].authorizationToken | base64 -d | cut -d: -f2`
        kubectl delete secret -n amazon-cloudwatch --ignore-not-found $RELEASE_TESTING_SECRET_NAME
        kubectl create secret -n amazon-cloudwatch docker-registry $RELEASE_TESTING_SECRET_NAME \
          --docker-server=https://${var.release_testing_ecr_account}.dkr.ecr.us-west-2.amazonaws.com \
          --docker-username=AWS \
          --docker-password="$${RELEASE_TESTING_TOKEN}"

        kubectl patch serviceaccount cloudwatch-agent -n amazon-cloudwatch -p='{"imagePullSecrets": [{"name": "release-testing-ecr-secret"}]}'
        kubectl delete pods --all -n amazon-cloudwatch
      elif [ "${var.repository}" = "amazon-cloudwatch-agent-operator" ]; then
        RELEASE_TESTING_SECRET_NAME=release-testing-ecr-secret
        RELEASE_TESTING_TOKEN=`aws ecr --region=us-west-2 get-authorization-token --output text --query authorizationData[].authorizationToken | base64 -d | cut -d: -f2`
        kubectl delete secret -n amazon-cloudwatch --ignore-not-found $RELEASE_TESTING_SECRET_NAME
        kubectl create secret -n amazon-cloudwatch docker-registry $RELEASE_TESTING_SECRET_NAME \
          --docker-server=https://${var.release_testing_ecr_account}.dkr.ecr.us-west-2.amazonaws.com \
          --docker-username=AWS \
          --docker-password="$${RELEASE_TESTING_TOKEN}"

        kubectl patch deploy -n amazon-cloudwatch amazon-cloudwatch-observability-controller-manager --type='json' -p='[{"op": "add", "path": "/spec/template/spec/imagePullSecrets", "value": [{"name": "release-testing-ecr-secret"}]}]'
        kubectl delete pods --all -n amazon-cloudwatch
      fi

      if [ "${var.repository}" = "amazon-cloudwatch-agent-operator" ]; then
        kubectl patch deploy -n amazon-cloudwatch amazon-cloudwatch-observability-controller-manager --type='json' -p '[{"op": "replace", "path": "/spec/template/spec/containers/0/image", "value": "${var.patch_image_arn}"}, {"op": "replace", "path": "/spec/template/spec/containers/0/imagePullPolicy", "value": "Always"}]]'
        kubectl delete pods --all -n amazon-cloudwatch
        sleep 10
        kubectl wait --for=condition=Ready pod --all -n amazon-cloudwatch
      elif [ "${var.repository}" = "amazon-cloudwatch-agent" ]; then
        kubectl patch amazoncloudwatchagents -n amazon-cloudwatch cloudwatch-agent --type='json' -p='[{"op": "replace", "path": "/spec/image", "value": ${var.patch_image_arn}}]'
        kubectl delete pods --all -n amazon-cloudwatch
        sleep 10
        kubectl wait --for=condition=Ready pod --all -n amazon-cloudwatch
      elif [ "${var.repository}" = "aws-otel-python-instrumentation" ]; then
        kubectl patch deploy -n amazon-cloudwatch amazon-cloudwatch-observability-controller-manager --type='json' \
        -p='[{"op": "replace", "path": "/spec/template/spec/containers/0/args/2", "value": "--auto-instrumentation-python-image=${var.patch_image_arn}"}]'
        kubectl delete pods --all -n amazon-cloudwatch
        sleep 10
        kubectl wait --for=condition=Ready pod --all -n amazon-cloudwatch
      fi

      # Create sample app namespace
      echo "LOG: Creating sample app namespace"
      kubectl create namespace python-sample-app-namespace

      # Set up secret to pull image with
      echo "LOG: Creating secret to access ECR images"
      ACCOUNT=$(aws sts get-caller-identity --query 'Account' --output text)
      SECRET_NAME=ecr-secret
      TOKEN=`aws ecr --region=${var.aws_region} get-authorization-token --output text --query authorizationData[].authorizationToken | base64 -d | cut -d: -f2`

      echo "LOG: Deleting secret if it exists"
      kubectl delete secret -n python-sample-app-namespace --ignore-not-found $SECRET_NAME

      echo "LOG: Creating secret for pulling sample app ECR"
      kubectl create secret -n python-sample-app-namespace docker-registry $SECRET_NAME \
      --docker-server=https://$ACCOUNT.dkr.ecr.${var.aws_region}.amazonaws.com \
      --docker-username=AWS \
      --docker-password="$${TOKEN}"

      # Deploy sample app
      echo "LOG: Pulling sample app deployment files"
      # cd to ensure everything is downloaded into root directory so cleanup is each
      cd ~
      aws s3api get-object --bucket aws-appsignals-sample-app-prod-us-east-1 --key python-frontend-service-depl-${var.repository}.yaml python-frontend-service-depl.yaml
      aws s3api get-object --bucket aws-appsignals-sample-app-prod-us-east-1 --key python-remote-service-depl-${var.repository}.yaml python-remote-service-depl.yaml

      # Patch the staging image if this is running as part of release testing
      if [ "${var.repository}" = "aws-otel-python-instrumentation" ]; then
        RELEASE_TESTING_SECRET_NAME=release-testing-ecr-secret
        kubectl delete secret -n python-sample-app-namespace --ignore-not-found $RELEASE_TESTING_SECRET_NAME
        kubectl create secret -n python-sample-app-namespace docker-registry $RELEASE_TESTING_SECRET_NAME \
          --docker-server=https://${var.release_testing_ecr_account}.dkr.ecr.us-east-1.amazonaws.com \
          --docker-username=AWS \
          --docker-password="$${TOKEN}"

        yq eval '.spec.template.spec.imagePullSecrets += [{"name": "release-testing-ecr-secret"}]' -i python-frontend-service-depl.yaml
        yq eval '.spec.template.spec.imagePullSecrets += [{"name": "release-testing-ecr-secret"}]' -i python-remote-service-depl.yaml
      fi

      echo "LOG: Applying sample app deployment files"
      kubectl apply -f python-frontend-service-depl.yaml
      kubectl apply -f python-remote-service-depl.yaml

      # Expose sample app on port 30100
      echo "LOG: Exposing main sample app on port 30100"
      kubectl expose deployment python-sample-app-deployment-${var.test_id} -n python-sample-app-namespace --type="NodePort" --port 8000
      kubectl patch service python-sample-app-deployment-${var.test_id} -n python-sample-app-namespace --type='json' --patch='[{"op": "replace", "path": "/spec/ports/0/nodePort", "value":30100}]'

      echo "Wait for sample app to be reach ready state"
      sleep 10
      kubectl wait --for=condition=Ready --request-timeout '10m' pod --all -n python-sample-app-namespace

      # Emit remote service pod IP
      echo "LOG: Outputting remote service pod IP to SSM using put-parameter API"
      aws ssm put-parameter --region ${var.aws_region} --name python-remote-service-ip-${var.test_id} --type String --overwrite --value $(kubectl get pod --selector=app=python-remote-app -n python-sample-app-namespace -o jsonpath='{.items[0].status.podIP}')
      EOF
    ]
  }
}
