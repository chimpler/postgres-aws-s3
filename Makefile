EXTENSION = aws_s3        # the extensions name
DATA = aws_s3--1.0.0.sql  # script files to install

# postgres build stuff
PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
