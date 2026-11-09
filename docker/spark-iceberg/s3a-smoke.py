# Runs inside the spark-iceberg image with --network=none.
# Creates an S3A FileSystem (no bucket probe) so the SDK v2 client, transfer manager and
# apache http client classes are loaded, and builds an Iceberg S3FileIO client.
# No network is needed for either; a missing class shows up as NoClassDefFoundError.
import os
os.environ.setdefault("AWS_ACCESS_KEY_ID", "smoke")
os.environ.setdefault("AWS_SECRET_ACCESS_KEY", "smoke")
from pyspark.sql import SparkSession

spark = (SparkSession.builder.master("local[1]").appName("s3a-smoke")
         .config("spark.ui.enabled", "false")
         .config("spark.hadoop.fs.s3a.endpoint", "http://127.0.0.1:9")
         .config("spark.hadoop.fs.s3a.endpoint.region", "us-east-1")
         .config("spark.hadoop.fs.s3a.path.style.access", "true")
         .config("spark.hadoop.fs.s3a.connection.ssl.enabled", "false")
         .config("spark.hadoop.fs.s3a.bucket.probe", "0")
         .config("spark.hadoop.fs.s3a.aws.credentials.provider",
                 "software.amazon.awssdk.auth.credentials.EnvironmentVariableCredentialsProvider")
         .getOrCreate())
jvm = spark._jvm
conf = spark._jsc.hadoopConfiguration()
fs = jvm.org.apache.hadoop.fs.FileSystem.get(jvm.java.net.URI("s3a://smoke/"), conf)
print("S3A:", fs.getClass().getName())
# touch the client explicitly (lazy in some versions)
print("S3A client:", fs.getS3AInternals().getAmazonS3Client("smoke").getClass().getName())

props = jvm.java.util.HashMap()
props.put("s3.endpoint", "http://127.0.0.1:9")
props.put("s3.path-style-access", "true")
props.put("client.region", "us-east-1")
io = jvm.org.apache.iceberg.aws.s3.S3FileIO()
io.initialize(props)
print("Iceberg S3FileIO client:", io.client().getClass().getName())
print("SMOKE-OK")
spark.stop()
