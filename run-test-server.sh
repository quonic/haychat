#!/usr/bin/env bash
set -e

export HAYCHAT_LOG_DIR=${HAYCHAT_LOG_DIR:-./logs}
export HAYCHAT_FILE_STORAGE_PATH=${HAYCHAT_FILE_STORAGE_PATH:-./storage}
export HAYCHAT_DATABASE_PASS=${HAYCHAT_DATABASE_PASS:-haychat}

odin run server