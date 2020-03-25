-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "CREATE EXTENSION aws_s3" to load this file. \quit

CREATE SCHEMA IF NOT EXISTS aws_commons;
CREATE SCHEMA IF NOT EXISTS aws_s3;


CREATE OR REPLACE FUNCTION aws_s3.table_import_from_s3 (
   table_name text,
   column_list text,
   options text,
   bucket text,
   file_path text,
   region text
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

    s3 = boto3.client('s3')

    # @ symbols are being interpolated as %40, which makes
    # the head_object call 404.
    # Replace this typo for now.
    formatted_file_path = file_path.replace('%40', '@')
    response = s3.head_object(Bucket=bucket, Key=formatted_file_path)
    content_encoding = response.get('ContentEncoding')

    with tempfile.NamedTemporaryFile() as fd:
        if content_encoding and content_encoding.lower() == 'gzip':
            with tempfile.NamedTemporaryFile() as gzfd:
                s3.download_fileobj(bucket, formatted_file_path, gzfd)
                gzfd.flush()
                gzfd.seek(0)
                shutil.copyfileobj(gzip.GzipFile(fileobj=gzfd, mode='rb'), fd)
        else:
                s3.download_fileobj(bucket, formatted_file_path, fd)
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
