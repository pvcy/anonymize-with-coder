terraform {
  required_providers {
    coder = {
      source  = "coder/coder"
      version = "~> 0.7.0"
    }
    google = {
      source  = "hashicorp/google"
      version = "~> 4.34.0"
    }
  }
}

provider "coder" {
}

variable "project_id" {
  description = "Which Google Compute Project should your workspace live in?"
}

data "coder_parameter" "zone" {
  name         = "zone"
  display_name = "Zone"
  description  = "Which zone should your workspace live in?"
  type         = "string"
  icon         = "/emojis/1f30e.png"
  default      = "us-central1-a"
  mutable      = false
  option {
    name  = "North America (Northeast)"
    value = "northamerica-northeast1-a"
    icon  = "/emojis/1f1fa-1f1f8.png"
  }
  option {
    name  = "North America (Central)"
    value = "us-central1-a"
    icon  = "/emojis/1f1fa-1f1f8.png"
  }
  option {
    name  = "North America (West)"
    value = "us-west2-c"
    icon  = "/emojis/1f1fa-1f1f8.png"
  }
  option {
    name  = "Europe (West)"
    value = "europe-west4-b"
    icon  = "/emojis/1f1ea-1f1fa.png"
  }
  option {
    name  = "South America (East)"
    value = "southamerica-east1-a"
    icon  = "/emojis/1f1e7-1f1f7.png"
  }
}

provider "google" {
  zone    = data.coder_parameter.zone.value
  project = var.project_id
}

data "google_compute_default_service_account" "default" {
}

data "coder_workspace" "me" {
}

resource "google_compute_disk" "root" {
  name  = "coder-${data.coder_workspace.me.id}-root"
  type  = "pd-ssd"
  zone  = data.coder_parameter.zone.value
  image = "debian-cloud/debian-11"
  lifecycle {
    ignore_changes = [name, image]
  }
}

resource "coder_agent" "main" {
  auth                   = "google-instance-identity"
  arch                   = "amd64"
  os                     = "linux"
  startup_script_timeout = 180
  startup_script         = <<-EOT
    set -e

    # Docker install
    if [ ! -e "/etc/apt/keyrings/docker.gpg" ]; then

      sudo apt update && sudo apt install -y ca-certificates curl gnupg
      sudo install -m 0755 -d /etc/apt/keyrings
      curl -fsSL https://download.docker.com/linux/debian/gpg | sudo gpg -v --batch --dearmor -o /etc/apt/keyrings/docker.gpg
      sudo chmod a+r /etc/apt/keyrings/docker.gpg

      echo \
      "deb [arch="$(dpkg --print-architecture)" signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \
      "$(. /etc/os-release && echo "$VERSION_CODENAME")" stable" | \
      sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
      sudo apt update && sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

      sudo usermod -aG docker "${local.linux_user}"
      newgrp docker
    else
      echo "Docker already installed, skipping..."
    fi

    if [ ! -d "$HOME/repos/anonymize-with-coder" ]; then
      install -m 0755 -d $HOME/repos
      echo "Cloning anonymize-with-coder repo"
      git clone https://github.com/pvcy/anonymize-with-coder $HOME/repos/anonymize-with-coder
      echo "Done cloning"
    else
      echo "Repo already exists. Skipping clone..."
    fi

    # Download snapshot if it doesn't exist
    if [ ! -d "/db-snapshots" ]; then
      sudo install -m 0755 -o "${local.linux_user}" -g "${local.linux_user}" -d /db-snapshots
    fi
    if [ ! -f "/db-snapshots/anonymize_demo_snap.sql" ]; then
      echo "DB Snapshot doesn't exist. Downloading..."
      gsutil cp gs://anonymize-demo-snapshots/anonymize_demo_snap.sql "/db-snapshots/"
    else
      echo "DB Snapshot already exists."
    fi

    # Install and start code-server
    curl -fsSL https://code-server.dev/install.sh | sh -s -- --method=standalone --prefix=/tmp/code-server --version 4.11.0
    /tmp/code-server/bin/code-server --auth none --port 13337 >/tmp/code-server.log 2>&1 &
  EOT

  metadata {
    key          = "cpu"
    display_name = "CPU Usage"
    interval     = 5
    timeout      = 5
    script       = <<-EOT
      #!/bin/bash
      set -e
      top -bn1 | grep "Cpu(s)" | awk '{print $2 + $4 "%"}'
    EOT
  }
  metadata {
    key          = "memory"
    display_name = "Memory Usage"
    interval     = 5
    timeout      = 5
    script       = <<-EOT
      #!/bin/bash
      set -e
      free -m | awk 'NR==2{printf "%.2f%%\t", $3*100/$2 }'
    EOT
  }
  metadata {
    key          = "disk"
    display_name = "Disk Usage"
    interval     = 600 # every 10 minutes
    timeout      = 30  # df can take a while on large filesystems
    script       = <<-EOT
      #!/bin/bash
      set -e
      df /home | awk '$NF=="/"{printf "%s", $5}'
    EOT
  }
}

# code-server
resource "coder_app" "code-server" {
  agent_id     = coder_agent.main.id
  slug         = "code-server"
  display_name = "code-server"
  icon         = "/icon/code.svg"
  url          = "http://localhost:13337?folder=/home/coder"
  subdomain    = false
  share        = "owner"

  healthcheck {
    url       = "http://localhost:13337/healthz"
    interval  = 3
    threshold = 10
  }
}

resource "google_compute_instance" "dev" {
  zone         = data.coder_parameter.zone.value
  count        = data.coder_workspace.me.start_count
  name         = "coder-${lower(data.coder_workspace.me.owner)}-${lower(data.coder_workspace.me.name)}-root"
  machine_type = "e2-medium"
  network_interface {
    network = "default"
    access_config {
      // Ephemeral public IP
    }
  }
  boot_disk {
    auto_delete = false
    source      = google_compute_disk.root.name
  }
  service_account {
    email  = data.google_compute_default_service_account.default.email
    scopes = ["cloud-platform"]
  }
  # The startup script runs as root with no $HOME environment set up, so instead of directly
  # running the agent init script, create a user (with a homedir, default shell and sudo
  # permissions) and execute the init script as that user.
  metadata_startup_script = <<EOMETA
#!/usr/bin/env sh
set -eux

# If user does not exist, create it
if ! id -u "${local.linux_user}" >/dev/null 2>&1; then
  echo "${local.linux_user} did not exist. Creating..."
  useradd -m -s /bin/bash "${local.linux_user}"
fi

# If user has not been added to sudoers, add it to set up passwordless sudo
if [ ! -f /etc/sudoers.d/coder-user ]; then
  echo "Coder user did not exist in sudoers. Creating..."
  echo "${local.linux_user} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/coder-user
fi

exec sudo -u "${local.linux_user}" sh -c '${coder_agent.main.init_script}'
EOMETA
}

locals {
  # Ensure Coder username is a valid Linux username
  linux_user = lower(substr(data.coder_workspace.me.owner, 0, 32))
}

resource "coder_metadata" "workspace_info" {
  count       = data.coder_workspace.me.start_count
  resource_id = google_compute_instance.dev[0].id

  item {
    key   = "type"
    value = google_compute_instance.dev[0].machine_type
  }
}

resource "coder_metadata" "home_info" {
  resource_id = google_compute_disk.root.id

  item {
    key   = "size"
    value = "${google_compute_disk.root.size} GiB"
  }
}

