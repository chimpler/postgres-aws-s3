# postgres-aws-s3

Starting on Postgres version 11.1, AWS RDS added [support](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_PostgreSQL.S3Import.html#USER_PostgreSQL.S3Import.FileFormats) for S3 import using the extension `aws_s3`. It allows to import data from S3 within Postgres using the function `aws_s3.table_import_from_s3` and export the data to S3 using the function `aws_s3.query_export_to_s3`.

In order to support development either on RDS or locally, we implemented our own `aws_s3` extension that is similar to
the one provided in RDS. It was implemented in Python using the boto3 library.

## Installation
Make sure boto3 is installed using the default Python 2 installed on your computer.
On MacOS, this can be done as follows:

    sudo /usr/bin/easy_install boto3

Then clone the repository `postgres-aws-s3`:

    git clone git@github.com:chimpler/postgres-aws-s3
    
Make sure that `pg_config` can be run:
```
$ pg_config 

BINDIR = /Applications/Postgres.app/Contents/Versions/13/bin
DOCDIR = /Applications/Postgres.app/Contents/Versions/13/share/doc/postgresql
HTMLDIR = /Applications/Postgres.app/Contents/Versions/13/share/doc/postgresql
INCLUDEDIR = /Applications/Postgres.app/Contents/Versions/13/include
PKGINCLUDEDIR = /Applications/Postgres.app/Contents/Versions/13/include/postgresql
INCLUDEDIR-SERVER = /Applications/Postgres.app/Contents/Versions/13/include/postgresql/server
LIBDIR = /Applications/Postgres.app/Contents/Versions/13/lib
...
```

Then install `postgres-aws-s3`:

    make install
    
Finally in Postgres:
```postgresql
psql> CREATE EXTENSION plpythonu;
psql> CREATE EXTENSION aws_s3;
``` 

If you already have an old version of `aws_s3` installed, you might want to drop and recreate the extension:
```postgresql
psql> DROP EXTENSION aws_s3;
psql> CREATE EXTENSION aws_s3;
```
    
## Using aws_s3

### Importing data using table_import_from_s3

Let's create a table that will import the data from S3:
```postgresql
psql> CREATE TABLE animals (
    name TEXT,
    age INT
);
```

Let's suppose the following file is present in s3 at `s3://test-bucket/animals.csv`:
```csv
name,age
dog,12
cat,15
parrot,103
tortoise,205
```

The function `aws_s3.table_import_from_s3` has 2 signatures that can be used.

#### Using s3_uri and aws_credentials objects

```postgresql
aws_s3.table_import_from_s3 (
   table_name text, 
   column_list text, 
   options text, 
   s3_info aws_commons._s3_uri_1,
   credentials aws_commons._aws_credentials_1,
   endpoint_url text default null
)
```

Using this signature, the `s3_uri` and `aws_credentials` objects will need to be created first:

Parameter | Description
----------|------------
table_name | the name of the table 
column_list | list of columns to copy
options | options passed to the COPY command in Postgres
s3_info | An aws_commons._s3_uri_1 composite type containing the bucket, file path and region information about the s3 object
credentials | An aws_commons._aws_credentials_1 composite type containing the access key, secret key, session token credentials
endpoint_url | optional endpoint to use (e.g., `http://localhost:4566`)

##### Example
```postgresql
psql> SELECT aws_commons.create_s3_uri(
   'test-bucket',
   'animals.csv',
   'us-east-1'
) AS s3_uri \gset

psql> \echo :s3_uri
(test-bucket,animals.csv,us-east-1)

psql> SELECT aws_commons.create_aws_credentials(
   '<my_access_id>',
   '<my_secret_key>',
   '<session_token>'
) AS credentials \gset

psql> \echo :credentials
(<my_access_id>,<my_secret_key>,<session_token>)

psql> SELECT aws_s3.table_import_from_s3(
   'animals',
   '',
   '(FORMAT CSV, DELIMITER '','', HEADER true)',
   :'s3_uri',
   :'credentials'
);

 table_import_from_s3
----------------------
                    4
(1 row)

psql> select * from animals;
   name   | age
----------+-----
 dog      |  12
 cat      |  15
 parrot   | 103
 tortoise | 205
(4 rows)
```

You can also call the function as:
```
psql> SELECT aws_s3.table_import_from_s3(
   'animals',
   '',
   '(FORMAT CSV, DELIMITER '','', HEADER true)',
   aws_commons.create_s3_uri(
      'test-bucket',
      'animals.csv',
      'us-east-1'
   ),
   aws_commons.create_aws_credentials(
      '<my_access_id>',
      '<my_secret_key>',
      '<session_token>'
   )
);
```

#### Using the function table_import_from_s3 with all the parameters

```postgresql
aws_s3.table_import_from_s3 (
   table_name text,
   column_list text,
   options text,
   bucket text,
   file_path text,
   region text,
   access_key text,
   secret_key text,
   session_token text,
   endpoint_url text default null
) 
```

Parameter | Description
----------|------------
table_name | the name of the table 
column_list | list of columns to copy
options | options passed to the COPY command in Postgres
bucket | S3 bucket
file_path | S3 path to the file
region | S3 region (e.g., `us-east-1`)
access_key | aws access key id
secret_key | aws secret key
session_token | optional session token
endpoint_url | optional endpoint to use (e.g., `http://localhost:4566`)

##### Example
```postgresql
psql> SELECT aws_s3.table_import_from_s3(
    'animals',
    '',
    '(FORMAT CSV, DELIMITER '','', HEADER true)',
    'test-bucket',
    'animals.csv',
    'us-east-1',
    '<my_access_id>',
    '<my_secret_key>',
    '<session_token>'
);

 table_import_from_s3
----------------------
                    4
(1 row)

psql> select * from animals;

   name   | age
----------+-----
 dog      |  12
 cat      |  15
 parrot   | 103
 tortoise | 205
(4 rows)
```

If you use localstack, you can set `endpoint_url` to point to the localstack s3 endpoint:
```
psql> SET aws_s3.endpoint_url TO 'http://localstack:4566'; 
```

You can also set the AWS credentials:
```
psql> SET aws_s3.aws_s3.access_key_id TO 'dummy';
psql> SET aws_s3.aws_s3.secret_key TO 'dummy';
psql> SET aws_s3.session_token TO 'dummy';
```
and then omit them from the function calls.

For example:
```
psql> SELECT aws_s3.table_import_from_s3(
    'animals',
    '',
    '(FORMAT CSV, DELIMITER '','', HEADER true)',
    'test-bucket',
    'animals.csv',
    'us-east-1'
);
```

You can pass them also as optional parameters. For example:
```
psql> SELECT aws_s3.table_import_from_s3(
    'animals',
    '',
    '(FORMAT CSV, DELIMITER '','', HEADER true)',
    'test-bucket',
    'animals.csv',
    'us-east-1',
    endpoint_url := 'http://localstack:4566'
);
```

#### Support for gzip files

If the file has the metadata `Content-Encoding=gzip` in S3, then the file will be automatically unzipped prior to be copied to the table.
One can update the metadata in S3 by following the instructions described [here](https://docs.aws.amazon.com/AmazonS3/latest/user-guide/add-object-metadata.html).


### Exporting data using query_export_to_s3

Documentation: https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/postgresql-s3-export.html

Similarly to the import functions, you can export the data using different methods.

#### Using s3_uri and aws_credentials objects

```
aws_s3.query_export_to_s3(
    query text,    
    s3_info aws_commons._s3_uri_1,
    credentials aws_commons._aws_credentials_1 default null,
    options text default null, 
    endpoint_url text default null
)
```

Using this signature, the `s3_uri` and optionally `aws_credentials` objects will need to be created first:

Parameter | Description
----------|------------
query | query that returns the data to export
s3_info | An aws_commons._s3_uri_1 composite type containing the bucket, file path and region information about the s3 object
credentials | An aws_commons._aws_credentials_1 composite type containing the access key, secret key, session token credentials
options | options passed to the COPY command in Postgres
endpoint_url | optional endpoint to use (e.g., `http://localhost:4566`)

##### Example
```postgresql
psql> SELECT * FROM aws_s3.query_export_to_s3(
   'select * from animals',
   aws_commons.create_s3_uri(
      'test-bucket',
      'animals2.csv',
      'us-east-1'
   ),
   aws_commons.create_aws_credentials(
      '<my_access_id>',
      '<my_secret_key>',
      '<session_token>'
   ),
   options := 'FORMAT CSV, DELIMITER '','', HEADER true'
);
```
If you set the AWS credentials:
```
psql> SET aws_s3.aws_s3.access_key_id TO 'dummy';
psql> SET aws_s3.aws_s3.secret_key TO 'dummy';
psql> SET aws_s3.session_token TO 'dummy';
```

You can omit the credentials.

##### Example

#### Using the function table_import_from_s3 with all the parameters
```
aws_s3.query_export_to_s3(
    query text,    
    bucket text,    
    file_path text,
    region text default null,
    access_key text default null,
    secret_key text default null,
    session_token text default null,
    options text default null, 
    endpoint_url text default null   
)
```

Parameter | Description
----------|------------
query | query that returns the data to export
bucket | S3 bucket
file_path | S3 path to the file
region | S3 region (e.g., `us-east-1`)
access_key | aws access key id
secret_key | aws secret key
session_token | optional session token
options | options passed to the COPY command in Postgres
endpoint_url | optional endpoint to use (e.g., `http://localhost:4566`)

##### Example
```postgresql
psql> SELECT * FROM aws_s3.query_export_to_s3(
   'select * from animals',
   'test-bucket',
   'animals.csv',
   'us-east-1',
    '<my_access_id>',
    '<my_secret_key>',
    '<session_token>',
   options:='FORMAT CSV, HEADER true'
);

 rows_uploaded | files_uploaded | bytes_uploaded
---------------+----------------+----------------
             5 |              1 |             47
```

If you set the AWS credentials:
```
psql> SET aws_s3.aws_s3.access_key_id TO 'dummy';
psql> SET aws_s3.aws_s3.secret_key TO 'dummy';
psql> SET aws_s3.session_token TO 'dummy';
```

You can omit the credential fields.

### Docker Compose

We provide a docker compose config to run localstack and postgres in docker containers. To start it:
```
$ docker-compose up
```

It will initialize a s3 server on port 4566 with a bucket test-bucket:
```
aws s3 --endpoint-url=http://localhost:4566 ls s3://test-bucket
```

You can connect to the postgres server:
```
$ psql -h localhost -p 15432 -U test test 
(password: test)
```

Initialize the extensions:
```
psql> CREATE EXTENSION plpythonu;
psql> CREATE EXTENSION aws_s3;
```

Set the endpoint url and the aws keys to use s3 (in localstack you can set the aws creds to any non-empty string):
```
psql> SET aws_s3.endpoint_url TO 'http://localstack:4566';
psql> SET aws_s3.s3.aws_access_key_id TO 'dummy';
psql> SET aws_s3.secret_access_key TO 'dummy';
```

Create a table animals:
```
psql> CREATE TABLE animals (
    name TEXT,
    age INT
);

psql> INSERT INTO animals (name, age) VALUES
('dog', 12),
('cat', 15),
('parrot', 103),
('tortoise', 205);
```

Export it to s3:
```
psql> select * from aws_s3.query_export_to_s3('select * from animals', 'test-bucket', 'animals.csv', 'us-east-1', options:='FORMAT CSV, HEADER true');
 rows_uploaded | files_uploaded | bytes_uploaded
---------------+----------------+----------------
             5 |              1 |             47
```

Import it back to another table:
```
psql> CREATE TABLE new_animals (LIKE animals);
psql> select * from aws_s3.query_export_to_s3('select * from animals', 'test-bucket', 'animals.csv', 'us-east-1', options:='FORMAT CSV, HEADER true');
 rows_uploaded | files_uploaded | bytes_uploaded
---------------+----------------+----------------
             4 |              1 |             38

psql> SELECT aws_s3.table_import_from_s3(
    'new_animals',
    '',
    '(FORMAT CSV, HEADER true)',
    'test-bucket',
    'animals.csv', 'us-east-1'
);
 table_import_from_s3
----------------------
                    4
(1 row)

psql> SELECT * FROM new_animals;
   name   | age
----------+-----
 dog      |  12
 cat      |  15
 parrot   | 103
 tortoise | 205
(4 rows)
```

## Contributors

* Oleksandr Yarushevskyi ([@oyarushe](https://github.com/oyarushe))
* Stephan Huiser ([@huiser](https://github.com/huiser))
* Jan Griesel ([@phileon](https://github.com/phileon))


## Thanks

* Thomas Gordon Lowrey IV [@gordol](https://github.com/gordol)
