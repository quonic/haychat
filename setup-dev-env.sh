#!/var/bin/env bash


# This script sets up a development environment for the HayChat project

# Check that llvm, clang, git, and llvm-config are installed
if ! command -v llvm &> /dev/null || ! command -v clang &> /dev/null || ! command -v git &> /dev/null || ! command -v llvm-config &> /dev/null; then
    echo "Error: llvm, clang, git, and llvm-config are required but not installed. Please install them and try again."
    echo "On apt systems, you can install them with: sudo apt install llvm llvm-dev clang git"
    echo "On dnf systems, you can install them with: sudo dnf install llvm llvm-devel clang git"
    exit 1
fi

# Change to the home directory
cd ~ || exit 1

# Check if odin command exists, if not, clone the Odin repository and build it

if ! command -v odin &> /dev/null || ! [ -d "Odin" ]; then
    echo "Odin not found, cloning and building Odin..."
    git clone https://github.com/odin-lang/Odin.git Odin || exit 1
    cd Odin || exit 1
    ./build_odin.sh || exit 1
    cd .. || exit 1
else
    echo "Odin found, skipping clone. Building Odin..."
    cd Odin || exit 1
    ./build_odin.sh || exit 1
    cd .. || exit 1
fi

# Change to the shared directory and clone the Skald and Odin PostgreSQL repositories
cd Odin/shared/ || exit 1
if [ -d "skald" ]; then
    echo "Skald repository already exists, updating..."
    cd skald || exit 1
    git pull || failed=1
    cd .. || exit 1
else
    echo "Cloning Skald repository..."
    cd ~ || exit 1
    git clone https://github.com/BuLEEto/Skald.git Skald || failed=1
    # Create a symbolic link to the Skald directory in the Odin/shared directory
    ln -s ~/Skald/skald ~/Odin/shared/skald || failed=1
    cd Odin/shared || exit 1
fi
if [ -d "pg" ]; then
    echo "Odin PostgreSQL repository already exists, updating..."
    cd pg || exit 1
    git pull || failed=1
    cd .. || exit 1
else
    echo "Cloning Odin PostgreSQL repository..."
    git clone https://github.com/laytan/odin-postgresql.git pg || failed=1
fi

if [ -n "$failed" ]; then
    echo "Error: Failed to clone one or more repositories."
    exit 1
fi