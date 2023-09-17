{
  description = "Development environment for signup-sequencer";

  inputs = {
    nixpkgs      = { url = "github:nixos/nixpkgs/nixpkgs-unstable"; };
    rust-overlay = { url = "github:oxalica/rust-overlay"; };
    flake-utils  = { url = "github:numtide/flake-utils"; };
    foundry      = { url = "github:shazow/foundry.nix/monthly"; };
  };

  outputs = { self, nixpkgs, rust-overlay, flake-utils, foundry, ... }:
    flake-utils.lib.eachDefaultSystem (system: let
      # change workdir for your own home, its important that it uses full path
      WORKDIR="/home/menko/Documents/reilabs/worldcoin/sequencer";
      # signup sequencer repo and directory
      SEQUENCER_REPO="https://github.com/worldcoin/signup-sequencer";
      SEQUENCER_DIR="${WORKDIR}/signup-sequencer";
      # world id contracts repo and directory
      WORLD_ID_REPO="https://github.com/worldcoin/world-id-contracts";
      WORLD_ID_DIR="${WORKDIR}/world-id-contracts";
      # semaphore mtb repo and directory
      SEMAPHORE_MTB_REPO="https://github.com/worldcoin/semaphore-mtb";
      SEMAPHORE_MTB_DIR="${WORKDIR}/semaphore-mtb";
      # Private key used with local ganache network (obviusly don't use this anywhere live)
      ACC_PRIV_KEY="0x135e302f7864f32cc437d522497ade6012862253e9495f46cd1f5d92092d5e45";
      RPC_URL="http://127.0.0.1:7545";
      TREE_DEPTH="16";
      BATCH_SIZE="3";
      # TODO: remove overlay when nix package updates to 0.8.21 // current 0.8.19
      solcOverlay = self: super: {
        solc = super.solc.overrideAttrs (oldAttrs: {
          patches = [];
          version = "0.8.21";
          src = super.fetchurl {
            url = "https://github.com/ethereum/solidity/releases/download/v0.8.21/solidity_0.8.21.tar.gz";
            sha256 = "sha256-bRu45yhQMg5y14hXX2vSXdSTDLbdnt01pZJmpG9hDRM=";
          };
        });
      };
      overlays      = [ (import rust-overlay) foundry.overlay solcOverlay];
      pkgs          = import nixpkgs { inherit system overlays; };
    in {
        devShell = pkgs.mkShell {
        buildInputs = [
          pkgs.expect
          pkgs.git
          # Rust
          pkgs.openssl
          pkgs.rust-bin.nightly.latest.default
          pkgs.rust-analyzer
          pkgs.clippy
          pkgs.pkg-config
          pkgs.protobuf
          # Golang
          pkgs.go
          pkgs.gopls
          pkgs.gotools
          pkgs.go-tools
          # Docker
          pkgs.docker
          pkgs.docker-compose
          # Node.js for contract generation
          pkgs.nodejs
          pkgs.nodePackages.ganache
          # Foundry
          pkgs.foundry-bin
          pkgs.solc
        ];

        shellHook = ''
          export PS1="\e[1;33m\][dev]\e[1;34m\] \w $ \e[0m\]";
          
          echo "################################################";
          echo "### Signup-sequencer flake development setup ###";
          echo "################################################";

          export OPENSSL_DIR="${pkgs.openssl.dev}"
          export OPENSSL_LIB_DIR="${pkgs.openssl.out}/lib"

          if [ ! -d "${SEQUENCER_DIR}" ]; then
            echo "Cloning sequencer repository..."
            git clone ${SEQUENCER_REPO} ${SEQUENCER_DIR}
          else
            echo "Sequencer folder exists. Skipping clone."
          fi
          
          if [ ! -d "${WORLD_ID_REPO}" ]; then
            echo "Cloning world id contracts repository..."
            git clone ${WORLD_ID_REPO} ${WORLD_ID_DIR}
          else
            echo "World id contracts folder exists. Skipping clone."
          fi

          if [ ! -d "${SEMAPHORE_MTB_REPO}" ]; then
            echo "Cloning semaphore-mtb repository..."
            git clone ${SEMAPHORE_MTB_REPO} ${SEMAPHORE_MTB_DIR}
          else
            echo "Semaphore-mtb folder exists. Skipping clone."
          fi

          echo "Starting or configuring ethereum chain..";
          pkill ganache-cli
          mkdir -p ${WORKDIR}/chain_network;
          ganache-cli --detach --db ${WORKDIR}/chain_network --account="${ACC_PRIV_KEY}, 150000000000000000000000" -i 1337 --server.port "7545" #> /dev/null 2>&1 &
          echo "Started ethereum chain.";
          
          echo "Building semaphore-mtb..";
          cd ${SEMAPHORE_MTB_DIR} && go build 2>&1;

          if [ $? -eq 0 ]; then
            echo "Semaphore-mtb build successful."
            read -p "Do you want generate mbu keys? (yes/no) " yn
            case $yn in
              yes ) echo "Generating keys.."
              cd ${SEMAPHORE_MTB_DIR} && ./gnark-mbu setup --batch-size ${BATCH_SIZE} --tree-depth ${TREE_DEPTH} --mode insertion --output keys
              echo "Keys generated."
              export KEYS_FILE=${SEMAPHORE_MTB_DIR}/keys;;
              * );;
            esac
            read -p "Do you want generate verifier contract? (yes/no) " yn
            case $yn in
              yes ) echo "Generating contract.."
              cd ${SEMAPHORE_MTB_DIR} && ./gnark-mbu export-solidity --keys-file keys --output verifier
              echo "verifier generated.";;
              * );;
            esac
          else
            echo "Semaphore-mtb build failed."
          fi

          read -p "Do you want to build and deploy contracts? (yes/no) " yn

          LOGFILE="${WORKDIR}/deploy_out.log";
          case $yn in 
            yes ) echo "Building worldcoin contracts..";
              cd ${WORLD_ID_DIR} && make > /dev/null 2>&1;

              # clear log file
              > $LOGFILE

              # Using expect to automate interactions
              expect <<EOD > /dev/null 2>&1
                log_file -a $LOGFILE
                set timeout 5
                spawn make deploy
                
                expect -re {Do you want to load configuration from prior runs?.*}
                send "n\r"
    
                expect -re {Enter your private key:.*}
                send "${ACC_PRIV_KEY}\r"
    
                expect -re {Enter RPC URL:.*}
                send "${RPC_URL}\r"
    
                expect -re {Enable State Bridge?.*}
                send "N\r"
    
                expect -re {Enable WorldID Router?.*}
                send "N\r"
    
                expect -re {Please provide the address of the insert verifier LUT \(or leave blank to deploy\):.*}
                send "\r"
    
                expect -re {Please provide the address of the update verifier LUT \(or leave blank to deploy\):.*}
                send "\r"
    
                expect -re {Enter batch size:.*}
                send "${BATCH_SIZE}\r"
    
                expect -re {Enter verifier contract address, or leave empty to deploy it:.*}
                send "\r"
    
                expect -re {Enter path to the Semaphore-MTB verifier contract file matching your batch size, or leave empty to generate it:.*}
                send "${SEMAPHORE_MTB_DIR}/verifier\r"

                expect -re {Enter initial root, or leave empty to compute based on tree depth.*}
                send "\r"
     
                expect -re {Enter tree depth.*}
                send "${TREE_DEPTH}\r"

                # expect -re {Enter path to the prover/verifier keys file, or leave empty to set it up:.*}
                # send "${SEMAPHORE_MTB_DIR}/keys\r"
    
                expect eof
EOD
            ;;
            no ) echo "Skipping contracts";;
            * ) echo "Invalid response";;
          esac

          MTB_VERIFIER=$(grep -oP 'Deployed MTB Verifier contract to \K0x[0-9a-fA-F]+' $LOGFILE)
          PAIRING_LIBRARY=$(grep -oP 'Deployed Pairing Library to \K0x[0-9a-fA-F]+' $LOGFILE)
          SEMAPHORE_VERIFIER=$(grep -oP 'Deployed Semaphore Verifier contract to \K0x[0-9a-fA-F]+' $LOGFILE)
          REG_VERIFIER_LUT=$(grep -oP 'Deployed Registration Verifier Lookup Table to \K0x[0-9a-fA-F]+' $LOGFILE)
          UPDATE_VERIFIER_LUT=$(grep -oP 'Deployed Update Verifier Lookup Table to \K0x[0-9a-fA-F]+' $LOGFILE)
          WORLDID_MANAGER_IMPL=$(grep -oP 'Deployed WorldID Identity Manager Implementation to \K0x[0-9a-fA-F]+' $LOGFILE)
          WORLDID_MANAGER=$(grep -oP 'Deployed WorldID Identity Manager to \K0x[0-9a-fA-F]+' $LOGFILE)

          read -p "Do you want to start a database with docker? (yes/no)" yn

          case $yn in 
            yes ) 
              echo "Starting database.."
              mkdir -p "${WORKDIR}/database-docker"

              if [[ ! -f "${WORKDIR}/database-docker/docker-compose.yaml" ]]; then 
                cat <<- EOL > "${WORKDIR}/database-docker/docker-compose.yaml"
                version: "3.9"
                services:
                  database:
                    image: postgres:14.5
                    restart: always
                    environment:
                      POSTGRES_USER: postgres
                      POSTGRES_PASSWORD: postgres
                      POSTGRES_DB: postgres
                      PGDATA: /var/lib/postgresql/data/pgdata
                    ports:
                      - "5432:5432"
                    volumes:
                      - .dbdata:/var/lib/postgresql/data
EOL
              fi

              cd "${WORKDIR}/database-docker"
              docker-compose down > /dev/null 2>&1
              docker-compose up > /dev/null 2>&1 &
              ;;

            no ) 
              echo "Skipping database"
              ;;

            * ) 
              echo "Invalid response"
              ;;
          esac

          echo "Building signup sequencer..";
          cd ${SEQUENCER_DIR} && cargo build > /dev/null 2>&1;

          if [ $? -eq 0 ]; then
            echo "Signup sequencer build successful."
          else
            echo "Signup sequencer build failed."
          fi

          read -p "Do you want to output signup-sequencer launch command?" yn;
          case $yn in 
          yes )
            echo TREE_DEPTH=${TREE_DEPTH} cargo run -- --batch-size ${BATCH_SIZE} --batch-timeout-seconds 10 --database postgres://postgres:postgres@postgres:5432 --identity-manager-address $WORLDID_MANAGER
                --signing-key ${ACC_PRIV_KEY}
            ;;
          * ) echo "Setup complete"
          ;;
          esac
          
          if command -v zsh >/dev/null 2>&1; then
            exec zsh
          else
            exec bash
          fi
          '';
      };
    });  
}
