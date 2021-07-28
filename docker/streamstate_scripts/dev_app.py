from pyspark.sql import SparkSession
from typing import List, Dict
import sys
from streamstate_utils.generic_wrapper import (
    dev_file_wrapper,
    write_console,
)
import os
from process import process
import json
from streamstate_utils.structs import (
    FileStruct,
    InputStruct,
)
from streamstate_utils.utils import get_folder_location
from pathlib import Path
import time


def _rename_files(path: str) -> List[str]:
    new_files = []
    for f in os.listdir(path):
        f_name, f_ext = os.path.splitext(f)
        time_since_epoch = time.time_ns()
        new_name = f"{f_name}_{time_since_epoch}{f_ext}"
        new_path = os.path.join(path, new_name)
        os.rename(os.path.join(path, f), new_path)
        new_files.append(new_path)
    return new_files


def _file_prep(
    app_name: str, base_folder: str, inputs: List[InputStruct]
) -> Dict[str, List[str]]:
    all_files = {}
    for input in inputs:
        folder = os.path.join(base_folder, get_folder_location(app_name, input.topic))
        Path(folder).mkdir(parents=True, exist_ok=True)
        all_files[input.topic] = _rename_files(folder)

    return all_files


def _update_input(input: InputStruct, files: Dict[str, List[str]]) -> InputStruct:
    samples = [sample for v in files[input.topic] for sample in _parse_file_to_dict(v)]
    return InputStruct(
        topic=input.topic, topic_schema=input.topic_schema, sample=samples
    )


def _parse_file_to_dict(file_location: str) -> List[dict]:
    """
    This parses badly formatted JSON (each line is a valid json but the entire file is not)
    and returns a list of each line's serialized json
    """
    with open(file_location, mode="r") as sample:
        return [json.loads(line) for line in sample]


def dev_from_file(app_name: str, max_file_age: str, inputs: List[InputStruct]):
    spark = SparkSession.builder.appName(app_name).getOrCreate()
    base_folder = "."
    _file_prep(app_name, base_folder, inputs)
    df = dev_file_wrapper(app_name, max_file_age, base_folder, process, inputs, spark)
    write_console(df, "/tmp")


def create_json_objects_for_unit_testing(
    app_name: str,
    max_file_age: str,
    inputs: List[InputStruct],
) -> Dict[str, List[dict]]:
    spark = SparkSession.builder.appName(app_name).getOrCreate()
    base_folder = "."
    files = _file_prep(app_name, base_folder, inputs)
    modified_inputs = [_update_input(input, files) for input in inputs]

    df = dev_file_wrapper(app_name, max_file_age, base_folder, process, inputs, spark)

    q = df.writeStream.format("memory").queryName(app_name).outputMode("append").start()
    q.processAllAvailable()
    result = spark.sql(f"select * from {app_name}")
    results = {
        "assertions": [json.loads(r) for r in result.toJSON().collect()],
        "inputs": modified_inputs,
    }
    q.stop()
    return results


# examples
# mode = "append"
# schema = [
#     (
#         "topic1",
#         {
#             "fields": [
#                 {"name": "first_name", "type": "string"},
#                 {"name": "last_name", "type": "string"},
#             ]
#         },
#     )
# ]
if __name__ == "__main__":
    [
        _,
        app_name,  #
        file_struct,
        input_struct,
    ] = sys.argv
    file_info = FileStruct(**json.loads(file_struct))
    input_info = [InputStruct(**v) for v in json.loads(input_struct)]
    dev_from_file(
        app_name,
        file_info.max_file_age,
        input_info,
    )
