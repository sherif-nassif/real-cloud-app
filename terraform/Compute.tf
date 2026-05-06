provider "google" {
  project = "project-d318db8d-3948-41a2-88d"
  region  = "europe-north2"
}

resource "google_compute_instance" "web_server" {
  name         = "app-server"
  machine_type = "e2-highmem-2"
  zone         = "europe-north2-a"

  boot_disk {
    initialize_params {
      image = "debian-13-trixie-v20260505"
      size  = 30
    }
  }

  network_interface {
    network = "default"
    access_config {}
  }

  metadata = {
    startup-script = file("user-data.sh")
  }

  tags = ["http-server", "https-server", "ssh-server"]

  service_account {
    scopes = ["cloud-platform"]
  }

  scheduling {
    automatic_restart   = true
    on_host_maintenance = "MIGRATE"
  }
}

output "instance_ip" {
  value = google_compute_instance.web_server.network_interface[0].access_config[0].nat_ip
}
