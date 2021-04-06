terraform {
  required_version = ">= 0.13"
  required_providers {
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = ">= 1.7.0"
    }
  }
}

# organization specific artifact repo
resource "google_artifact_registry_repository" "orgrepo" {
  provider      = google-beta
  project       = var.project
  location      = "us-central1"
  repository_id = var.organization
  description   = "organization specific docker repo"
  format        = "DOCKER"
}
# organization specific data bucket
resource "google_storage_bucket" "sparkstorage" {
  project                     = var.project
  name                        = "streamstate-sparkstorage-${var.organization}"
  location                    = "US"
  force_destroy               = true
  uniform_bucket_level_access = true
}
##################
# Service accounts in google, to be mapped to kuberenetes secrets
##################


# it would be nice for this to be per app, but may not be feasible 
# since may not be able to create service accounts per job.
# Remember...I want all gcp resources defined through TF
# this is the service acccount for spark jobs and 
# can write to spark storage

resource "google_service_account" "docker-write" {
  project      = var.project
  account_id   = "docker-write-${var.organization}"
  display_name = "docker-write-${var.organization}"
}

#write access to organization artifactory
resource "google_artifact_registry_repository_iam_member" "providereadwrite" {
  provider   = google-beta
  project    = var.project
  location   = google_artifact_registry_repository.orgrepo.location
  repository = google_artifact_registry_repository.orgrepo.name
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${google_service_account.docker-write.email}"
}
# read access to project wide artifactory
resource "google_artifact_registry_repository_iam_member" "read" {
  provider   = google-beta
  project    = var.project
  location   = "us-central1"
  repository = var.project # see ../../global/global.tf#  
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${google_service_account.docker-write.email}"
}

resource "google_service_account" "spark-gcs" {
  project      = var.project
  account_id   = "spark-gcs-${var.organization}"
  display_name = "Spark Service account ${var.organization}"
}

#write access to gcs
resource "google_storage_bucket_iam_member" "sparkadmin" {
  bucket = google_storage_bucket.sparkstorage.name
  role   = "roles/storage.admin"
  member = "serviceAccount:${google_service_account.spark-gcs.email}"
}

resource "google_artifact_registry_repository_iam_member" "clusterread" {
  provider   = google-beta
  project    = var.project
  location   = google_artifact_registry_repository.orgrepo.location
  repository = google_artifact_registry_repository.orgrepo.name
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${var.cluster_email}"
}


##################
# Set up connection to GKE
##################
data "google_client_config" "default" {
}

provider "kubernetes" {
  host                   = var.cluster_endpoint
  token                  = data.google_client_config.default.access_token
  cluster_ca_certificate = base64decode(var.cluster_ca_cert)
}
provider "helm" {
  kubernetes {
    host                   = var.cluster_endpoint
    token                  = data.google_client_config.default.access_token
    cluster_ca_certificate = base64decode(var.cluster_ca_cert)
  }
}
provider "kubectl" {
  host                   = var.cluster_endpoint
  token                  = data.google_client_config.default.access_token
  cluster_ca_certificate = base64decode(var.cluster_ca_cert)
}

data "template_file" "kubeconfig" {
  template = file("${path.module}/kubeconfig.yml")

  vars = {
    cluster_name  = var.cluster_name
    endpoint      = var.cluster_endpoint
    cluster_ca    = var.cluster_ca_cert
    cluster_token = data.google_client_config.default.access_token
  }
}
# I believe this is needed to persist auth for more than 60 minutes
# careful!  this is sensitive, I believe
resource "local_file" "kubeconfig" {
  depends_on = [var.cluster_id]
  content    = data.template_file.kubeconfig.rendered
  filename   = "${path.root}/kubeconfig"
}

##################
# Create Kubernetes resources
##################
resource "kubernetes_namespace" "mainnamespace" {
  metadata {
    name = var.namespace
  }
}

resource "kubernetes_namespace" "argoevents" {
  metadata {
    name = "argo-events"
  }
}

##################
# Map GCP service accounts to kubernetes service accounts
##################


# see https://cloud.google.com/kubernetes-engine/docs/how-to/workload-identity#gcloud
# this works with google service account binding to connect kubernetes and google accounts
resource "kubernetes_service_account" "docker-cfg-write-events" {
  metadata {
    name      = "docker-cfg-write"
    namespace = kubernetes_namespace.argoevents.metadata.0.name
    annotations = {
      "iam.gke.io/gcp-service-account" = google_service_account.docker-write.email
    }
  }
  depends_on = [kubernetes_namespace.argoevents]
}

# see https://cloud.google.com/kubernetes-engine/docs/how-to/workload-identity#gcloud
# link service account and kubernetes service account
resource "google_service_account_iam_binding" "bind_docker_write_argo" {
  service_account_id = google_service_account.docker-write.name
  role               = "roles/iam.workloadIdentityUser"

  members = [
    "serviceAccount:${var.project}.svc.id.goog[${kubernetes_namespace.argoevents.metadata.0.name}/${kubernetes_service_account.docker-cfg-write-events.metadata.0.name}]",
  ]
  depends_on = [
    kubernetes_service_account.docker-cfg-write-events
  ]
}

# use this for running steps in argo
resource "kubernetes_role" "argorules" {
  metadata {
    name      = "argoroles"
    namespace = kubernetes_namespace.argoevents.metadata.0.name
  }
  rule {
    api_groups = [""]
    resources  = ["pods"]
    verbs      = ["get", "list", "watch", "patch"]
  }
  rule {
    api_groups = ["argoproj.io"]
    resources  = ["workflows"]
    verbs      = ["get", "list"]
  }
  depends_on = [kubernetes_namespace.argoevents]
}

resource "kubernetes_role_binding" "dockerwrite" {
  metadata {
    name      = "dockerwriteargopermissions-role-binding"
    namespace = kubernetes_namespace.argoevents.metadata.0.name
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.argorules.metadata.0.name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.docker-cfg-write-events.metadata.0.name
    namespace = kubernetes_namespace.argoevents.metadata.0.name
  }
}



resource "kubernetes_service_account" "spark" {
  metadata {
    name      = "spark"
    namespace = kubernetes_namespace.mainnamespace.metadata.0.name
  }
  depends_on = [kubernetes_namespace.argoevents]
}

## need to create explicit account for spark rather than workload identity
resource "google_service_account_key" "sparkkey" {
  service_account_id = google_service_account.spark-gcs.name
}

resource "kubernetes_secret" "spark-gcs-to-kubernetes" {
  metadata {
    name      = "spark-secret"
    namespace = kubernetes_namespace.mainnamespace.metadata.0.name
  }
  data = {
    "key.json" = base64decode(google_service_account_key.sparkkey.private_key)
  }
}

## needed for operating spark resources
resource "kubernetes_role" "sparkrules" {
  metadata {
    name      = "sparkrules"
    namespace = kubernetes_namespace.mainnamespace.metadata.0.name
  }
  rule {
    api_groups = [""]
    resources  = ["pods"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }
  depends_on = [kubernetes_namespace.mainnamespace]
}

resource "kubernetes_role_binding" "sparkrules" {
  metadata {
    name      = "sparkrules-role-binding"
    namespace = kubernetes_namespace.mainnamespace.metadata.0.name
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.sparkrules.metadata.0.name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.spark.metadata.0.name
    namespace = kubernetes_namespace.mainnamespace.metadata.0.name
  }
}




##################
# Standalone kubernetes service accounts and secrets
##################


resource "random_password" "cassandra_password" {
  length  = 32
  special = true
}

resource "random_string" "cassandra_userid" {
  length  = 8
  special = false
}
resource "kubernetes_secret" "cassandra_svc" {
  metadata {
    name      = "cassandra-secret"
    namespace = kubernetes_namespace.mainnamespace.metadata.0.name
  }
  data = {
    username = random_string.cassandra_userid.result
    password = random_password.cassandra_password.result
  }
  type       = "kubernetes.io/generic"
  depends_on = [kubernetes_namespace.mainnamespace]
}

resource "kubernetes_service_account" "cassandra_svc" {
  metadata {
    name      = "cassandra-svc"
    namespace = kubernetes_namespace.mainnamespace.metadata.0.name
  }

  secret {
    name = kubernetes_secret.cassandra_svc.metadata.0.name
  }
  depends_on = [kubernetes_namespace.mainnamespace]
}

resource "kubernetes_service_account" "argoevents-runsa" {
  metadata {
    name      = "argoevents-runsa"
    namespace = kubernetes_namespace.argoevents.metadata.0.name
  }
  depends_on = [kubernetes_namespace.argoevents]
}

resource "kubernetes_role_binding" "argoevents-runrb" {
  metadata {
    name      = "argoevents-runsa-role-binding"
    namespace = kubernetes_namespace.argoevents.metadata.0.name
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.argorules.metadata.0.name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.argoevents-runsa.metadata.0.name
    namespace = kubernetes_namespace.argoevents.metadata.0.name
  }
}


resource "kubernetes_service_account" "launchsparkoperator" {
  metadata {
    name      = "launchspark"
    namespace = kubernetes_namespace.mainnamespace.metadata.0.name
  }
  depends_on = [kubernetes_namespace.mainnamespace]
}
resource "kubernetes_cluster_role" "launchsparkoperator" {
  metadata {
    name = "launchsparkoperator-role"
  }
  rule {
    api_groups = ["sparkoperator.k8s.io"]
    resources  = ["sparkapplications"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }
  depends_on = [kubernetes_namespace.mainnamespace]
}
resource "kubernetes_cluster_role_binding" "launchsparkoperator" {
  metadata {
    name = "launchspark-role-binding"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.launchsparkoperator.metadata.0.name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.launchsparkoperator.metadata.0.name
    namespace = kubernetes_namespace.mainnamespace.metadata.0.name
  }
}

##################
# Install Cassandra
##################

resource "helm_release" "cassandra" {
  name             = "cass-operator"
  namespace        = "cass-operator"
  create_namespace = true
  repository       = "https://datastax.github.io/charts"
  chart            = "cass-operator"

  set {
    name  = "clusterWideInstall"
    value = true
  }
  depends_on = [local_file.kubeconfig]
}

data "kubectl_file_documents" "cassandra" {
  content = templatefile("../../gke/cassandra.yml", { secret = kubernetes_secret.cassandra_svc.metadata.0.name })
}

resource "kubectl_manifest" "cassandra" {
  count              = 3 # length(data.kubectl_file_documents.cassandra.documents)
  yaml_body          = element(data.kubectl_file_documents.cassandra.documents, count.index)
  override_namespace = kubernetes_namespace.mainnamespace.metadata.0.name
  depends_on         = [helm_release.cassandra]
}

##################
# Install Spark
##################
resource "helm_release" "spark" {
  name             = "spark-operator"
  namespace        = "spark-operator"
  create_namespace = true
  repository       = "https://googlecloudplatform.github.io/spark-on-k8s-operator"
  chart            = "spark-operator"
  set {
    name  = "webhook.enable"
    value = true
  }
  depends_on = [local_file.kubeconfig] # needed to ensure that this gets destroyed in right order
}


##################
# Install Argo
##################


data "kubectl_file_documents" "argoworkflow" {
  content = file("../../argo/argoinstall.yml")
}
resource "kubectl_manifest" "argoworkflow" {
  count              = length(data.kubectl_file_documents.argoworkflow.documents)
  yaml_body          = element(data.kubectl_file_documents.argoworkflow.documents, count.index)
  override_namespace = kubernetes_namespace.argoevents.metadata.0.name
  depends_on         = [kubernetes_namespace.argoevents]
}

data "kubectl_file_documents" "argoevents" {
  content = file("../../argo/argoeventsinstall.yml")
}

resource "kubectl_manifest" "argoevents" {
  count              = length(data.kubectl_file_documents.argoevents.documents)
  yaml_body          = element(data.kubectl_file_documents.argoevents.documents, count.index)
  override_namespace = kubernetes_namespace.argoevents.metadata.0.name
  depends_on         = [kubectl_manifest.argoworkflow]
}

data "kubectl_file_documents" "argoeventswebhook" {
  content = file("../../argo/webhookinstall.yml")
}

resource "kubectl_manifest" "argoeventswebhook" {
  count              = length(data.kubectl_file_documents.argoeventswebhook.documents)
  yaml_body          = element(data.kubectl_file_documents.argoeventswebhook.documents, count.index)
  override_namespace = kubernetes_namespace.argoevents.metadata.0.name
  depends_on         = [kubectl_manifest.argoevents]
}

data "kubectl_file_documents" "argoeventworkflow" {
  content = templatefile("../../argo/eventworkflow.yml", {
    project           = var.project,
    dockersecretwrite = kubernetes_service_account.docker-cfg-write-events.metadata.0.name,
    registry          = google_artifact_registry_repository.orgrepo.name
    registryprefix    = var.registryprefix
    runserviceaccount = kubernetes_service_account.argoevents-runsa.metadata.0.name
  })
}
## The docker containers needed for this are built as part of the CI/CD pipeline that
## includes provisioning global TF, so the images will be available
## question: which images?  The latest?  Or specific tags?
resource "kubectl_manifest" "argoeventworkflow" {
  count              = 1
  yaml_body          = element(data.kubectl_file_documents.argoeventworkflow.documents, count.index)
  override_namespace = kubernetes_namespace.argoevents.metadata.0.name
  depends_on         = [kubectl_manifest.argoeventswebhook]
}

# data "kubectl_file_documents" "ingressmain" {
#   content = templatefile("../../gke/ingressmainspark.yml", {
#     organization = var.organization
#   })
# }

# resource "kubectl_manifest" "ingressmain" {
#   count              = 1
#   yaml_body          = element(data.kubectl_file_documents.ingressmain.documents, count.index)
#   override_namespace = kubernetes_namespace.mainnamespace.metadata.0.name
# }

# data "kubectl_file_documents" "ingressargo" {
#   content = templatefile("../../gke/ingressargo.yml", {
#     organization = var.organization
#   })
# }

# resource "kubectl_manifest" "ingressargo" {
#   count              = 1
#   yaml_body          = element(data.kubectl_file_documents.ingressargo.documents, count.index)
#   override_namespace = kubernetes_namespace.argoevents.metadata.0.name
# }




data "kubectl_file_documents" "restapi" {
  content = templatefile("../../gke/restapi.yml", {
    launchspark     = kubernetes_service_account.launchsparkoperator.metadata.0.name,
    cassandrasecret = kubernetes_secret.cassandra_svc.metadata.0.name
  })
}

resource "kubectl_manifest" "restapi" {
  count              = 2 # length(data.kubectl_file_documents.restapi.documents)
  yaml_body          = element(data.kubectl_file_documents.restapi.documents, count.index)
  override_namespace = kubernetes_namespace.mainnamespace.metadata.0.name
}