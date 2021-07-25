from pyspark.sql import SparkSession, DataFrame
from typing import List
import sys
from streamstate_utils.generic_wrapper import (
    dev_file_wrapper,
    write_wrapper,
    write_json,
)
import os
from process import process
import json
from streamstate_utils.structs import FileStruct, InputStruct, OutputStruct
from streamstate_utils.utils import get_folder_location
from pathlib import Path
import shutil


def dev_from_file(
    app_name: str,
    max_file_age: str,
    inputs: List[InputStruct],
    num_rows_to_print: int = 10,
):
    spark = SparkSession.builder.appName(app_name).getOrCreate()
    base_folder = "."
    for input in inputs:
        Path(
            os.path.join(base_folder, get_folder_location(app_name, input.topic))
        ).mkdir(parents=True, exist_ok=True)

    output_topic = "output"
    output_path = os.path.join(base_folder, get_folder_location(app_name, output_topic))
    dirpath = Path(output_path)
    if dirpath.exists() and dirpath.is_dir():
        shutil.rmtree(output_path)
    Path(output_path).mkdir(parents=True)

    df = dev_file_wrapper(app_name, max_file_age, base_folder, process, inputs, spark)

    def dual_write(batch_df: DataFrame):
        batch_df.persist()
        batch_df.show(num_rows_to_print)
        write_json(batch_df, app_name, base_folder, output_topic)

    output = OutputStruct(mode="append")
    write_wrapper(df, output, "/tmp", dual_write)


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
