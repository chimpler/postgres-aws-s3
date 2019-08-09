-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "CREATE EXTENSION aws_s3" to load this file. \quit

CREATE SCHEMA IF NOT EXISTS aws_commons;
CREATE SCHEMA IF NOT EXISTS aws_s3;

DROP TYPE IF EXISTS aws_commons._s3_uri_1 CASCADE;
CREATE TYPE aws_commons._s3_uri_1 AS (bucket TEXT, file_path TEXT, region TEXT);

DROP TYPE IF EXISTS aws_commons._aws_credentials_1 CASCADE;
CREATE TYPE aws_commons._aws_credentials_1 AS (access_key TEXT, secret_key TEXT, session_token TEXT);

--
-- Create a aws_commons._s3_uri_1 object that holds the bucket, key and region
--

CREATE OR REPLACE FUNCTION aws_commons.create_s3_uri(
   s3_bucket text,
   s3_key text,
   aws_region text
) RETURNS aws_commons._s3_uri_1
LANGUAGE plpythonu IMMUTABLE
AS $$
    return (s3_bucket, s3_key, aws_region)
$$;

--
-- Create a aws_commons._aws_credentials_1 object that holds the access_key, secret_key and session_token
--

CREATE OR REPLACE FUNCTION aws_commons.create_aws_credentials(
    access_key text,
    secret_key text,
    session_token text
) RETURNS aws_commons._aws_credentials_1
LANGUAGE plpythonu IMMUTABLE
AS $$
    return (access_key, secret_key, session_token)
$$;

CREATE OR REPLACE FUNCTION aws_s3.table_import_from_s3 (
   table_name text,
   column_list text,
   options text,
   bucket text,
   file_path text,
   region text,
   access_key text,
   secret_key text,
   session_token text
) RETURNS int
LANGUAGE plpythonu
AS $$
    def cache_import(module_name):
        module_cache = SD.get('__modules__', {})
        if module_name in module_cache:
            return module_cache[module_name]
        else:
            import importlib
            _module = importlib.import_module(module_name)
            if not module_cache:
                SD['__modules__'] = module_cache
            module_cache[module_name] = _module
            return _module

    os = cache_import('os')

    boto3 = cache_import('boto3')
    tempfile = cache_import('tempfile')
    gzip = cache_import('gzip')
    shutil = cache_import('shutil')

    plan = plpy.prepare('select current_setting($1, true)::int', ['TEXT'])

    s3 = boto3.client(
        's3',
        aws_access_key_id=access_key,
        aws_secret_access_key=secret_key,
        aws_session_token=session_token,
        region_name=region,
        endpoint_url=os.environ.get('S3_ENDPOINT_URL')
    )

    response = s3.head_object(Bucket=bucket, Key=file_path)
    content_encoding = response.get('ContentEncoding')

    with tempfile.NamedTemporaryFile() as fd:
        if content_encoding and content_encoding.lower() == 'gzip':
            with tempfile.NamedTemporaryFile() as gzfd:
                s3.download_fileobj(bucket, file_path, gzfd)
                gzfd.flush()
                gzfd.seek(0)
                shutil.copyfileobj(gzip.GzipFile(fileobj=gzfd, mode='rb'), fd)
        else:
                s3.download_fileobj(bucket, file_path, fd)
        fd.flush()
        res = plpy.execute("COPY {table_name} ({column_list}) FROM {filename} {options};".format(
                table_name=table_name,
                filename=plpy.quote_literal(fd.name),
                column_list=column_list,
                options=options
            )
        )
        return res.nrows()
$$;

CREATE OR REPLACE FUNCTION aws_s3.table_import_from_s3 (
   table_name text,
   column_list text,
   options text,
   bucket text,
   file_path text,
   region text,
   access_key text,
   secret_key text,
   session_token text,
   endpoint_url text
) RETURNS int
LANGUAGE plpythonu
AS $$
    def cache_import(module_name):
        module_cache = SD.get('__modules__', {})
        if module_name in module_cache:
            return module_cache[module_name]
        else:
            import importlib
            _module = importlib.import_module(module_name)
            if not module_cache:
                SD['__modules__'] = module_cache
            module_cache[module_name] = _module
            return _module

    boto3 = cache_import('boto3')
    tempfile = cache_import('tempfile')
    gzip = cache_import('gzip')
    shutil = cache_import('shutil')

    plan = plpy.prepare('select current_setting($1, true)::int', ['TEXT'])

    s3 = boto3.client(
        's3',
        endpoint_url=endpoint_url,
        aws_access_key_id=access_key,
        aws_secret_access_key=secret_key,
        aws_session_token=session_token,
        region_name=region
    )

    response = s3.head_object(Bucket=bucket, Key=file_path)
    content_encoding = response.get('ContentEncoding')

    with tempfile.NamedTemporaryFile() as fd:
        if content_encoding and content_encoding.lower() == 'gzip':
            with tempfile.NamedTemporaryFile() as gzfd:
                s3.download_fileobj(bucket, file_path, gzfd)
                gzfd.flush()
                gzfd.seek(0)
                shutil.copyfileobj(gzip.GzipFile(fileobj=gzfd, mode='rb'), fd)
        else:
                s3.download_fileobj(bucket, file_path, fd)
        fd.flush()
        res = plpy.execute("COPY {table_name} ({column_list}) FROM {filename} {options};".format(
                table_name=table_name,
                filename=plpy.quote_literal(fd.name),
                column_list=column_list,
                options=options
            )
        )
        return res.nrows()
$$;

--
-- S3 function to import data from S3 into a table
--

CREATE OR REPLACE FUNCTION aws_s3.table_import_from_s3(
   table_name text,
   column_list text,
   options text,
   s3_info aws_commons._s3_uri_1,
   credentials aws_commons._aws_credentials_1
) RETURNS INT
LANGUAGE plpythonu
AS $$
    plan = plpy.prepare(
        'SELECT aws_s3.table_import_from_s3($1, $2, $3, $4, $5, $6, $7, $8, $9) AS num_rows',
        ['TEXT', 'TEXT', 'TEXT', 'TEXT', 'TEXT', 'TEXT', 'TEXT', 'TEXT', 'TEXT']
    )
    return plan.execute(
        [
            table_name,
            column_list,
            options,
            s3_info['bucket'],
            s3_info['file_path'],
            s3_info['region'],
            credentials['access_key'],
            credentials['secret_key'],
            credentials['session_token']
        ]
    )[0]['num_rows']
$$;

CREATE OR REPLACE FUNCTION aws_s3.table_import_from_s3(
   table_name text,
   column_list text,
   options text,
   s3_info aws_commons._s3_uri_1,
   credentials aws_commons._aws_credentials_1,
   endpoint_url text
) RETURNS INT
LANGUAGE plpythonu
AS $$
    plan = plpy.prepare(
        'SELECT aws_s3.table_import_from_s3($1, $2, $3, $4, $5, $6, $7, $8, $9) AS num_rows',
        ['TEXT', 'TEXT', 'TEXT', 'TEXT', 'TEXT', 'TEXT', 'TEXT', 'TEXT', 'TEXT', 'TEXT']
    )
    return plan.execute(
        [
            table_name,
            column_list,
            options,
            s3_info['bucket'],
            s3_info['file_path'],
            s3_info['region'],
            credentials['access_key'],
            credentials['secret_key'],
            credentials['session_token'],
	    endpoint_url
        ]
    )[0]['num_rows']
$$;
