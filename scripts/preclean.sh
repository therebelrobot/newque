#! /bin/bash

# Compilation folder
rm -rf tmp

# Folders created by running Newque
rm -rf logs
rm -rf data

# Remove the autogenerated files when cleaning
rm -rf src/config/config_*.ml*
rm -rf src/serialization/json_obj_*.ml*
rm -rf src/serialization/zmq_obj_pb.ml*
