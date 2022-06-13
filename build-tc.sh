#!/usr/bin/env bash

# Secret Variable for CI
# LLVM_NAME | Your desired Toolchain Name
# TG_TOKEN | Your Telegram Bot Token
# TG_CHAT_ID | Your Telegram Channel / Group Chat ID
# GH_USERNAME | Your Github Username
# GH_EMAIL | Your Github Email
# GH_TOKEN | Your Github Token ( repo & repo_hook )
# GL_TOKEN | Your GitLab Token (read_user, read_repository, write_repository)
# GH_PUSH_REPO_URL | Your GitHub Repository for store compiled Toolchain ( without https:// or www. ) ex. github.com/cbendot/elastics-clang.git
# GL_PUSH_REPO_URL | Your GitLab Repository

# Function to show an informational message
msg() {
    echo -e "\e[1;32m$*\e[0m"
}

err() {
    echo -e "\e[1;41m$*\e[0m"
}

# Set a directory
DIR="$(pwd ...)"

# Inlined function to post a message
export BOT_MSG_URL="https://api.telegram.org/bot$TG_TOKEN/sendMessage"
tg_post_msg() {
	curl -s -X POST "$BOT_MSG_URL" -d chat_id="$TG_CHAT_ID" \
	-d "disable_web_page_preview=true" \
	-d "parse_mode=html" \
	-d text="$1"
}
tg_post_build() {
	curl --progress-bar -F document=@"$1" "$BOT_MSG_URL" \
	-F chat_id="$TG_CHAT_ID"  \
	-F "disable_web_page_preview=true" \
	-F "parse_mode=html" \
	-F caption="$3"
}

# Build Info
rel_date="$(date "+%Y%m%d")" # ISO 8601 format
rel_friendly_date="$(date "+%B %-d, %Y")" # "Month day, year" format
builder_commit="$(git rev-parse HEAD)"
START=$(date +"%s")

# Send a notificaton to TG
tg_post_msg "<b>Elastics Clang Compilation Started</b>%0A<b>Vendor : </b><code>$LLVM_NAME clang</code>%0A<b>Toolchain Script Commit : </b><code>$builder_commit</code>%0A<b>Build Date : </b><code>$rel_friendly_date</code>"

# Build LLVM
msg "Building LLVM..."
tg_post_msg "<b>Building LLVM...</b>"
./build-llvm.py \
	--clang-vendor "$LLVM_NAME" \
	--projects "clang;lld;polly" \
	--targets "ARM;AArch64" \
	--shallow-clone \
	--incremental \
	--build-type "Release" 2>&1 | tee build.log

# Check if the final clang binary exists or not.
[ ! -f install/bin/clang-1* ] && {
	err "Building LLVM failed ! Kindly check errors !!"
	tg_post_build "build.log" "$TG_CHAT_ID" "Error Log"
	exit 1
}

# Build binutils
msg "Building Binutils..."
tg_post_msg "<b>Building Binutils...</b>"
./build-binutils.py --targets arm aarch64

# Remove unused products
rm -fr install/include
rm -f install/lib/*.a install/lib/*.la

# Strip remaining products
for f in $(find install -type f -exec file {} \; | grep 'not stripped' | awk '{print $1}'); do
	strip -s "${f: : -1}"
done

# Set executable rpaths so setting LD_LIBRARY_PATH isn't necessary
for bin in $(find install -mindepth 2 -maxdepth 3 -type f -exec file {} \; | grep 'ELF .* interpreter' | awk '{print $1}'); do
	# Remove last character from file output (':')
	bin="${bin: : -1}"

	echo "$bin"
	patchelf --set-rpath "$DIR/install/lib" "$bin"
done

# Release Info
pushd llvm-project || exit
llvm_commit="$(git rev-parse HEAD)"
short_llvm_commit="$(cut -c-8 <<< "$llvm_commit")"
popd || exit

llvm_commit_url="https://github.com/llvm/llvm-project/commit/$short_llvm_commit"
binutils_ver="$(ls | grep "^binutils-" | sed "s/binutils-//g")"
clang_version="$(install/bin/clang --version | head -n1 | cut -d' ' -f4)"

tg_post_msg "<b>Pushed to Repository Started...</b>%0A<b>Clang Version : </b><code>$clang_version</code>%0A<b>Binutils Version : </b><code>$binutils_ver</code>%0A<b>LLVM Commit: </b><code>$llvm_commit_url</code>%0A<b>Builder Commit: </b><code>https://github.com/cbendot/tcbuild/commit/$builder_commit</code>%0A<b>Elastics Clang Bump to: </b><code>$rel_date build</code>"

# Push to GitHub
# Update Git repository
git config --global user.name $GH_USERNAME
git config --global user.email $GH_EMAIL
git clone "https://ben863:$GL_TOKEN@$GL_PUSH_REPO_URL" rel_repo
pushd rel_repo || exit
rm -fr ./*
cp -r ../install/* .
git checkout README.md # keep this as it's not part of the toolchain itself
git add .
git commit -asm "$LLVM_NAME Clang: Bump to $rel_date build

LLVM commit: $llvm_commit_url
Clang Version: $clang_version
Binutils version: $binutils_ver
Builder commit: https://github.com/cbendot/tcbuild/commit/$builder_commit"

# Downgrade the HTTP version to 1.1
git config --global http.version HTTP/1.1
# Increase git buffer size
git config --global http.postBuffer 55428800
git lfs migrate import --everything --include="bin/llvm-lto2"
git lfs migrate import --everything --include="bin/bugpoint"
git lfs migrate import --everything --include="bin/opt"
git lfs migrate import --everything --include="bin/clang-15"
git lfs migrate import --everything --include="bin/clang-scan-deps"
git lfs migrate import --everything --include="lib/libclang.so.15.0.0git"
git lfs migrate import --everything --include="bin/clang-repl"
git lfs migrate import --everything --include="bin/lld"
git lfs migrate import --everything --include="lib/libclang-cpp.so.15git"

git push -f
popd || exit

# Set git buffer to original size
git config --global http.version HTTP/2

END=$(date +"%s")
DIFF=$(($END - $START))
tg_post_msg "<b>Pushed to Repository Done !</b>%0A%0A<code>$((DIFF / 60)) minute(s) $((DIFF % 60)) second(s) </code>"