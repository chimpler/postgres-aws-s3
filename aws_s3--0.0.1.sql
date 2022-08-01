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
LANGUAGE plpython3u IMMUTABLE
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
LANGUAGE plpython3u IMMUTABLE
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
   access_key text default null,
   secret_key text default null,
   session_token text default null,
   endpoint_url text default null
) RETURNS int
LANGUAGE plpython3u
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

    plan = plpy.prepare("select name, current_setting('aws_s3.' || name, true) as value from (select unnest(array['access_key_id', 'secret_access_key', 'session_token', 'endpoint_url']) as name) a");
    default_aws_settings = {
        row['name']: row['value']
        for row in plan.execute()
    }

    aws_settings = {
        'aws_access_key_id': access_key if access_key else default_aws_settings.get('access_key_id', 'unknown'),
        'aws_secret_access_key': secret_key if secret_key else default_aws_settings.get('secret_access_key', 'unknown'),
        'aws_session_token': session_token if session_token else default_aws_settings.get('session_token'),
        'endpoint_url': endpoint_url if endpoint_url else default_aws_settings.get('endpoint_url')
    }

    s3 = boto3.resource(
        's3',
        region_name=region,
        **aws_settings
    )

    obj = s3.Object(bucket, file_path)
    response = obj.get()
    content_encoding = response.get('ContentEncoding')
    body = response['Body']
    user_content_encoding = response.get('x-amz-meta-content-encoding')

    with tempfile.NamedTemporaryFile() as fd:
        if (content_encoding and content_encoding.lower() == 'gzip') or (user_content_encoding and user_content_encoding.lower() == 'gzip'):
            with gzip.GzipFile(fileobj=body) as gzipfile:
                while fd.write(gzipfile.read(204800)):
                    pass
        else:
            while fd.write(body.read(204800)):
                pass
        fd.flush()
        formatted_column_list = "({column_list})".format(column_list=column_list) if column_list else ''
        res = plpy.execute("COPY {table_name} {formatted_column_list} FROM {filename} {options};".format(
                table_name=table_name,
                filename=plpy.quote_literal(fd.name),
                formatted_column_list=formatted_column_list,
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
   credentials aws_commons._aws_credentials_1,
   endpoint_url text default null
) RETURNS INT
LANGUAGE plpython3u
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

CREATE OR REPLACE FUNCTION aws_s3.query_export_to_s3(
    query text,    
    bucket text,    
    file_path text,
    region text default null,
    access_key text default null,
    secret_key text default null,
    session_token text default null,
    options text default null, 
    endpoint_url text default null,
    OUT rows_uploaded bigint,
    OUT files_uploaded bigint,
    OUT bytes_uploaded bigint
) RETURNS SETOF RECORD
LANGUAGE plpython3u
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

    plan = plpy.prepare("select name, current_setting('aws_s3.' || name, true) as value from (select unnest(array['access_key_id', 'secret_access_key', 'session_token', 'endpoint_url']) as name) a");
    default_aws_settings = {
        row['name']: row['value']
        for row in plan.execute()
    }

    aws_settings = {
        'aws_access_key_id': access_key if access_key else default_aws_settings.get('access_key_id', 'unknown'),
        'aws_secret_access_key': secret_key if secret_key else default_aws_settings.get('secret_access_key', 'unknown'),
        'aws_session_token': session_token if session_token else default_aws_settings.get('session_token'),
        'endpoint_url': endpoint_url if endpoint_url else default_aws_settings.get('endpoint_url')
    }

    s3 = boto3.client(
        's3',
        region_name=region,
        **aws_settings
    )

    with tempfile.NamedTemporaryFile() as fd:
        plan = plpy.prepare(
            "COPY ({query}) TO '{filename}' {options}".format(
                query=query,
                filename=fd.name,
                options="({options})".format(options=options) if options else ''
            )
        )
        plan.execute()
        num_lines = 0
        size = 0
        while True:
            buffer = fd.read(8192 * 1024)
            if not buffer:
                break

            num_lines += buffer.count(b'\n')
            size += len(buffer)
        fd.seek(0)
        s3.upload_fileobj(fd, bucket, file_path)
        if 'HEADER TRUE' in options.upper():
            num_lines -= 1
        yield (num_lines, 1, size)
$$;

CREATE OR REPLACE FUNCTION aws_s3.query_export_to_s3(
    query text,    
    s3_info aws_commons._s3_uri_1,
    credentials aws_commons._aws_credentials_1 default null,
    options text default null, 
    endpoint_url text default null,
    OUT rows_uploaded bigint,
    OUT files_uploaded bigint,
    OUT bytes_uploaded bigint
) RETURNS SETOF RECORD
LANGUAGE plpython3u
AS $$
    plan = plpy.prepare(
        'SELECT * FROM aws_s3.query_export_to_s3($1, $2, $3, $4, $5, $6, $7, $8, $9)',
        ['TEXT', 'TEXT', 'TEXT', 'TEXT', 'TEXT', 'TEXT', 'TEXT', 'TEXT', 'TEXT']
    )
    return plan.execute(
        [
            query,
            s3_info.get('bucket'),
            s3_info.get('file_path'),
            s3_info.get('region'),
            credentials.get('access_key') if credentials else None,
            credentials.get('secret_key') if credentials else None,
            credentials.get('session_token') if credentials else None,
            options,
	        endpoint_url
        ]
    )
$$;
