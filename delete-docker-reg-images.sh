#!/bin/bash

JQPATH=$(which jq)
if [ "x$JQPATH" == "x" ]; then
  echo "Couldn't find jq executable." 1>&2
  exit 2
fi

set -eu
shopt -s nullglob

readonly base_dir=/var/lib/docker/registry
readonly output_dir=$(mktemp -d -t trace-images-XXXX)
readonly jq=$JQPATH

readonly repository_dir=$base_dir/repositories
readonly image_dir=$base_dir/images

readonly all_images=$output_dir/all
readonly used_images=$output_dir/used
readonly unused_images=$output_dir/unused

function info() {
    echo -e "\nArtifacts available in $output_dir"
}
trap info EXIT ERR INT

function image_history() {
    local readonly image_hash=$1
    $jq '.[]' $image_dir/$image_hash/ancestry | tr -d  '"'
}

echo "Collecting orphan images"
for library in $repository_dir/*; do
    echo "Library $(basename $library)" >&2

    for repo in $library/*; do
        echo " Repo $(basename $repo)" >&2

        for tag in $repo/tag_*; do
            echo "  Tag $(basename $tag)" >&2

            tagged_image=$(cat $tag)
            image_history $tagged_image
        done
    done
done | sort | uniq > $used_images

ls $image_dir > $all_images

grep -v -F -f $used_images $all_images > $unused_images

readonly all_image_count=$(wc -l $all_images | awk '{print $1}')
readonly used_image_count=$(wc -l $used_images | awk '{print $1}')
readonly unused_image_count=$(wc -l $unused_images | awk '{print $1}')
readonly unused_image_size=$(cd $image_dir; du -hc $(cat $unused_images) | tail -n1 | cut -f1)

echo "${all_image_count} images, ${used_image_count} used, ${unused_image_count} unused"
echo "Unused images consume ${unused_image_size}"

echo -e "\nTrimming _index_images..."
readonly unused_images_flatten=$output_dir/unused.flatten
cat $unused_images | sed -e 's/\(.*\)/\"\1\" /' | tr -d "\n" > $unused_images_flatten

for library in $repository_dir/*; do
    echo "Library $(basename $library)" >&2

    for repo in $library/*; do
        echo " Repo $(basename $repo)" >&2
        mkdir -p "$output_dir/$(basename $repo)"
        jq '.' "$repo/_index_images" > "$output_dir/$(basename $repo)/_index_images.old"
        jq -s '.[0] - [ .[1:][] | {id: .} ]' "$repo/_index_images" $unused_images_flatten > "$output_dir/$(basename $repo)/_index_images"
        cp "$output_dir/$(basename $repo)/_index_images" "$repo/_index_images"
    done
done

echo -e "\nRemoving images"
cat $unused_images | xargs -I{} rm -rf $image_dir/{}