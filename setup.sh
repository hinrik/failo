#!/bin/bash
FAILO="/home/failo"

# Failo dirs
mkdir -p $FAILO/brains

# Link dotfiles
if type link-files > /dev/null; then
    link-files --source . --dest $FAILO -a setup.sh -a README.mkdn
else
    echo "Perl module File::Linkdir not installed; dotfiles not linked"
    exit 1
fi

