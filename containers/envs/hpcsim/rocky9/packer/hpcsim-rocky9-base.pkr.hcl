packer {
  required_plugins {
    docker = {
      source  = "github.com/hashicorp/docker"
      version = ">= 1.1.0"
    }
  }
}

variable "base_image" {
  type    = string
  default = "rockylinux:9"
}

variable "docker_platform" {
  type    = string
  default = "linux/amd64"
}

variable "archive_path" {
  type    = string
  default = "../../../../out/hpcsim-rocky9-base.tar"
}

variable "image_repository" {
  type    = string
  default = "chapar/hpcsim-rocky9-base"
}

variable "image_tag" {
  type    = string
  default = "latest"
}

source "docker" "rocky9" {
  image    = var.base_image
  pull     = true
  commit   = true
  platform = var.docker_platform

  changes = [
    "ENV CHAPAR_ENV_NAME=hpcsim",
    "ENV CHAPAR_ENV_ROOT=/resources/chapar/hpcsim",
    "ENV CHAPAR_ENV_OS=rocky9",
    "ENTRYPOINT [\"/usr/local/bin/chapar-env-entrypoint\"]",
    "CMD [\"bash\", \"--login\"]"
  ]
}

build {
  name    = "hpcsim-rocky9-base"
  sources = ["source.docker.rocky9"]

  provisioner "file" {
    source      = "../packages.txt"
    destination = "/tmp/chapar-rocky9-packages.txt"
  }

  provisioner "file" {
    source      = "../../../../common/bin/chapar-env-entrypoint"
    destination = "/usr/local/bin/chapar-env-entrypoint"
  }

  provisioner "file" {
    source      = "../../../../../etc/profile.d/zz-chapar-hpcsim.sh"
    destination = "/etc/profile.d/zz-chapar-hpcsim.sh"
  }

  provisioner "shell" {
    environment_vars = [
      "CHAPAR_PACKAGE_LIST=/tmp/chapar-rocky9-packages.txt",
      "CHAPAR_ENV_NAME=hpcsim"
    ]
    script = "../provision-rocky9.sh"
  }

  post-processors {
    post-processor "docker-tag" {
      repository = var.image_repository
      tags       = [var.image_tag]
    }

    post-processor "docker-save" {
      path = var.archive_path
    }
  }
}
