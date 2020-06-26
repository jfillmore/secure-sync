#!/bin/bash -u

BASE_DIR=$(cd $(dirname "$0") && pwd -P)
SCRIPT_NAME=$(basename "$0")


# ==========================================
# functions
# ==========================================

usage() {
    cat <<EOI
Usage: $SCRIPT_NAME [ARGUMENTS] PATH [PATH...] -- [...TAR_ARGS]

Uploads or downloads an encrypted gzipped tarball. When uploading, all paths
must be relative unless there is just one.

Uploads:    PATH [...PATH] s3://(PATH/)?NAME  # multiple local paths may be used
Downloads:  s3://(PATH/)?NAME PATH  # PATH = dir to download and extact files to

Passing '--' causes all remaining arguments to be passed to "tar" on uploads.

ARGUMENTS:

  -d|--dry-run          Run without making any changes
  -h|--help             This information
  -v|--verbose          Print debugging information to stdout
  --                    Remaining args are passed to "tar"

ENV VARS:

  SECURE_SYNC_KEY       Location of key file (only used during cert creation)  
                        (default: \$HOME/.secure-sync.key)
  SECURE_SYNC_CRT       Location of certificate file for encrypt/decrypt
                        (default: \$HOME/.secure-sync.crt)
  SECURE_SYNC_IGNORE    Location of file containing patterns (one-per-line) to
                        ignore on uploads (default: \$HOME/.secure-sync.ignore)

EXAMPLES:

# we'll need this to encrypt/decrypt data (path shown is default)
# if it doesn't exist we'll be prompted to create it
$ export SECURE_SYNC_KEY=~/.secure-sync.key  # only needed to generate a cert
$ export SECURE_SYNC_CRT=~/.secure-sync.pem

# upload just one dir
$ $SCRIPT_NAME ~/code s3://backups/code-apr-5-2020.ssdata

# upload a few files/directories
$ $SCRIPT_NAME pictures/ scripts/ s3://backups/data-apr-5-2020.ssdata -- --exclude .*.sw?

# download and extact saved data
$ $SCRIPT_NAME s3://backups/code-apr-5-2020.ssdata ~/code
EOI
}

fail() {
    echo "[1;31m${1-command failed}[0;0m" >&2
    exit ${2:-1}
}

rem() {
    [ "$VERBOSE" -eq 1 ] && echo -e "+ [\033[1;37m$@\033[0;0m]" >&2
}

cmd() {
    if [ $DRYRUN -eq 1 ]; then
        echo -e "\033[0;33m# $(printf "'%s' " "$@")\033[0;0m" >&2
    else
        [ $VERBOSE -eq 1 ] \
            && echo -e "\033[0;33m# $(printf "'%s' " "$@")\033[0;0m" >&2
        "$@"
    fi
}

prompt_yn() {
    local msg="${1:-confinue?}"
    local resp=''
    while [ "$resp" != 'y' -a "$resp" != 'n' ]; do
        read -n 1 -p "[1;36m$msg [0;36m(y|n) >[0;0m " resp
        echo
    done
    [ "$resp" = 'y' ] && return 0 || return 1
}

# S3 crap:
# - no errors if deletion fails because:
#   - didn't add trailing / to folder
#   - there were foldes/files


# ==========================================
# collect args
# ==========================================

VERBOSE=0
DRYRUN=0
SECURE_SYNC_KEY="${SECURE_SYNC_KEY:-$HOME/.secure-sync.key}"
SECURE_SYNC_CRT="${SECURE_SYNC_CRT:-$HOME/.secure-sync.pem}"
SECURE_SYNC_IGNORE="${SECURE_SYNC_IGNORE:-$HOME/.secure-sync.ignore}"
SYNC_DIR=  # if we have a single path we'll cd here first

bucket_path=
is_upload=
seen_split=0
tar_args=()
paths=()


while [ $# -gt 0 ]; do
    arg="$1"
    shift
    case "$arg" in 
        --dry-run|-d)
            DRYRUN=1
            ;;
        --verbose|-v)
            VERBOSE=1
            ;;
        --help|-h)
            usage
            exit
            ;;
        --arg|-a)
            [ $# -ge 1 ] || fail "Missing arg to --arg|-a"
            some_arg="$1"
            shift
            ;;
        --bool|-b)
            bool_arg=1
            ;;
        *)
            # once we parse '--' everything is a tar arg
            [ "$arg" = '--' ] && {
                [ $is_upload -eq 1 ] || fail "Extra args to 'tar' only allowed on uploads"
                seen_split=1
                continue
            }
            if [ $seen_split = 1 ]; then
                tar_args+=("$arg")
                continue
            fi

            # first arg will tell us if we're an upload or not
            [ -n "$is_upload" ] || {
                [  "${arg:0:5}" = 's3://' ] && {
                    is_upload=0
                    tar_args=("-xzf" "-")
                } || {
                    is_upload=1
                    tar_args=("-czf" "-")
                }
            }
            # figure out and validate what type of arg this is (bucket or path)
            if [ $is_upload -eq 1 ]; then
                # if there are still more args this is a path, as the last is a bucket
                if [ "${arg:0:5}" = 's3://' ]; then
                    [ -n "$bucket_path" ] && fail "The bucket path '$bucket_path' was already given"
                    bucket_path="$arg"
                else
                    [ -f "$arg" -o -d "$arg" ] || fail "The path '$arg' is not a file or directory"
                    # absolute paths have limits...
                    if [ "${arg:0:1}" = '~' -o "${arg:0:1}" = '/' ]; then
                        # ensure we don't have more than one
                        [ ${#paths[*]} -eq 0 ] || fail "Paths must be relative to upload multiple items"
                        # get our parent dir for the upload
                        [ -d "$arg" ] \
                            && SYNC_DIR=$(cd "$arg/.." && pwd -P) \
                            || SYNC_DIR=$(cd "$(dirname "$arg")" && pwd -P)
                        paths+=("$(basename "$arg")")
                    else
                        paths+=("$arg")
                    fi
                fi
            else
                # the first param will be an s3 bucket, the last a path (and only one)
                if [ -z "$bucket_path" ]; then
                    bucket_path="$arg"
                else
                    [ ${#paths[*]} -eq 0 ] || fail "Only one download path can be given"
                    paths+=("$arg")
                    SYNC_DIR="$arg"
                fi
            fi
            ;;
    esac
done


# ==========================================
# sanity checks
# ==========================================
# options are sane?
[ -n "$is_upload" ] || {
    usage
    fail "No arguments given"
}
[ -n "$bucket_path" ] || {
     usage
     fail "A bucket name (+path) is required"
}
[ ${#paths[@]} -eq 0 ] && {
    usage
    [ -n "$is_upload" ] \
        && fail "No files or folders listed for upload" \
        || fail "No folder given to download to"
}
# ensure we have the the right CLI tools
which aws &>/dev/null || fail "Please install the AWS CLI (https://aws.amazon.com/cli/)"
which openssl &>/dev/null || fail "Please install OpenSSL"
# ensure creds work... this should be a reasonable assumption to be able to do
aws iam get-user &>/dev/null || fail "Failed to fetch user information; check perms and creds"


# ==========================================
# main script logic
# ==========================================
# make sure we have a valid certificate and key
[ -f "$SECURE_SYNC_CRT" -a -f "$SECURE_SYNC_KEY" ] || {
    umask 077 || fail "Failed to set umask to 077?"
    prompt_yn "Key file $SECURE_SYNC_CRT does not exist... create it?" \
        || fail "Aborting; no valid key file"
    rem "Creating new secure sync key file: '$SECURE_SYNC_KEY'"
    req_file="$HOME/.$SCRIPT_NAME.csr"
    openssl_args=(
        -newkey rsa:2048
        -keyout "$SECURE_SYNC_KEY"
        -out "$req_file"
        -subj '/C=../ST=./L=./O=./OU=./CN=.'
    )
    prompt_yn "Do you want to require a passphrase to encrypt/decrypt data?" \
        || openssl_args+=("-nodes")
    openssl req "${openssl_args[@]}" || {
        rm "$req_file"
        rm "$SECURE_SYNC_KEY"
        fail "Failed to generate OpenSSL CSR"
    }
    rem "Creating new secure sync certificate: '$SECURE_SYNC_CRT'"
    openssl x509 \
        -req \
        -in "$req_file" \
        -signkey "$SECURE_SYNC_KEY" \
        -out "$SECURE_SYNC_CRT" \
        || fail "Failed to generate OpenSSL certificate"
    cat << EOI
[1;32mSuccess![1;37m Please ensure you don't lose (or forget their location) these files.
You'll specifically need the certificate file to upload/download files. If
generated with a passphrase, you'll need that every time you sync files.

- Key File: [1;33m$SECURE_SYNC_KEY[1;37m
- Certificate File: [1;33m$SECURE_SYNC_CRT[0;0m
EOI
}

# a bit of prep work
if [ -n "$SYNC_DIR" ]; then
    [ -d "$SYNC_DIR" ] || {
        prompt_yn "Create new directory '$SYNC_DIR'?" \
            || fail "Cowardly refusing to go on"
        mkdir -p "$SYNC_DIR" &>/dev/null || fail "Failed to create '$SYNC_DIR'"
    }
    cd "$SYNC_DIR" || fail "Failed to cd to '$SYNC_DIR'"
    [ $VERBOSE -eq 1 ] && tar_args+=("-v")
    [ $DRYRUN -eq 1 ] && rem "DRY RUN"
fi

# and now the action!
if [ $is_upload -eq 1 ]; then
    # look for stuff to auto-ignore
    [ -s "$SECURE_SYNC_IGNORE" ] && {
        tar_args+=($(sed 's/^/--exclude /' < "$SECURE_SYNC_IGNORE"))
    }
    # gotta make sure the bucket exists
    path="${bucket_path#s3://*}"
    bucket="${path%%/*}"
    aws s3api get-bucket-location --bucket "$bucket" &>/dev/null || {
        rem "Creating new bucket '$bucket'"
        cmd aws s3 mb "s3://$bucket" &>/dev/null || fail "Failed to create bucket 's3:/$bucket'"
    }
    # and stream our encrypted upload!
    rem "Uploading to '$bucket_path': ${paths[@]}"
    tar "${tar_args[@]}" "${paths[@]}" \
        | openssl smime -encrypt -aes256 -binary -outform DER "$SECURE_SYNC_CRT" \
        | cmd aws s3 cp - "$bucket_path" \
        || fail "Failed to send encrypted upload to '$bucket_path'"
else
    # easy-peasy: stream that download!
    aws s3 cp "$bucket_path" - \
        | openssl smime -decrypt -inform DER -inkey "$SECURE_SYNC_KEY" \
        | cmd tar "${tar_args[@]}" \
        || fail "Failed to fetch encrypted data from '$bucket_path'"
fi

exit 0
