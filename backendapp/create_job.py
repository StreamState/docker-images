import yaml
from kubernetes import client, config
from kubernetes.client.api import CustomObjectsApi
from create_body import (
    spark_state_job_spec,
    spark_persist_job_spec,
    spark_replay_file_spec,
)
from kubernetes.client.api_client import ApiClient
from typing import List
from request_body import Job, create_table_name


def yaml_load(path: str) -> dict:
    with open(path) as file:
        # The FullLoader parameter handles the conversion from YAML
        # scalar values to Python the dictionary format
        spec = yaml.load(file, Loader=yaml.FullLoader)

        return spec


files = [
    "../sparkstreaming/spark-streaming-job-template.yaml",
]


def load_all_ymls(paths: List[str]) -> List[dict]:
    return [yaml_load(ymlFile) for ymlFile in paths]


def construct_image(registry: str, project: str, organization: str, image: str) -> str:
    return f"{registry}/{project}/{organization}/{image}"


def create_replay_job(
    apiclient: ApiClient, spark_job: dict, pay_load: Job
) -> List[str]:
    api = client.CustomObjectsApi(apiclient)
    exceptions: List[str] = []
    spark_job = spark_replay_file_spec(
        spark_job,
        construct_image(
            pay_load.registry,
            pay_load.project,
            pay_load.organization,
            "streamstate:v0.1.0",
        ),
        pay_load.brokers,
        pay_load.topics,
        pay_load.output_topic,
        "test-group-id",
        "2d",
        pay_load.namespace,
        pay_load.project,
        pay_load.organization,
        create_table_name(
            pay_load.organization, pay_load.avro_schema["name"], pay_load.version
        ),
        pay_load.cassandra_cluster_name,
    )
    try:
        api_response = api.create_namespaced_custom_object(
            body=spark_job,
            namespace=pay_load.namespace,
            group="sparkoperator.k8s.io",
            version="v1beta2",
            plural="sparkapplications",
        )
    except Exception as e:
        exceptions.append(str(e))

    return exceptions


def create_all_spark_jobs(
    apiclient: ApiClient, spark_job: dict, pay_load: Job
) -> List[str]:
    api = client.CustomObjectsApi(apiclient)
    exceptions: List[str] = []
    for topic in pay_load.topics:
        file_persist_local = spark_job.copy()
        file_persist_local = spark_persist_job_spec(
            file_persist_local,
            construct_image(
                pay_load.registry,
                pay_load.project,
                pay_load.organization,
                "streamstate:v0.1.0",
            ),
            pay_load.brokers,
            topic,
            "test-group-id",
            "2s",
            pay_load.namespace,
            pay_load.project,
            pay_load.organization,
        )
        # this can throw, so make sure that we catch that when calling this function
        try:
            api_response = api.create_namespaced_custom_object(
                body=file_persist_local,
                namespace=pay_load.namespace,
                group="sparkoperator.k8s.io",
                version="v1beta2",
                plural="sparkapplications",
            )
        except Exception as e:
            exceptions.append(str(e))
    name = "-".join(pay_load.topics)
    spark_job = spark_state_job_spec(
        spark_job,
        construct_image(
            pay_load.registry,
            pay_load.project,
            pay_load.organization,
            "streamstate:v0.1.0",
        ),
        pay_load.brokers,
        pay_load.topics,
        pay_load.output_topic,
        "test-group-id",
        pay_load.namespace,
        pay_load.project,
        pay_load.organization,
        create_table_name(
            pay_load.organization, pay_load.avro_schema["name"], pay_load.version
        ),
        pay_load.cassandra_cluster_name,
    )
    # this can throw, so make sure that we catch that when calling this function
    try:
        api_response = api.create_namespaced_custom_object(
            body=spark_job,
            namespace=pay_load.namespace,
            group="sparkoperator.k8s.io",
            version="v1beta2",
            plural="sparkapplications",
        )
    except Exception as e:
        exceptions.append(str(e))
    return exceptions


if __name__ == "__main__":
    config.load_incluster_config()
    apiclient = ApiClient()
    [spark_job] = load_all_ymls(files)
    create_all_spark_jobs(
        apiclient,
        # file_persist,
        spark_job,
        Job(
            topics=["topic1"],
            brokers=["broker1"],
            namespace="mainspark",
            cassandra_cluster_name="cluster1",
            project="streamstatetest",
            organization="testorg",
            registry="us-central1-docker.pkg.dev",
        ),
    )
