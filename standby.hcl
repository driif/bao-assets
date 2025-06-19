storage "raft" {
  path    = "./data-standby"
  node_id = "standby"

  retry_join {
    leader_api_addr = "http://127.0.0.1:8200"
  }
}

listener "tcp" {
  address = "127.0.0.1:8210"
  tls_disable = true
  cluster_address = "127.0.0.1:8211"
}

cluster_addr = "http://127.0.0.1:8211"
api_addr = "http://127.0.0.1:8210"

ui = false
log_level = "Debug"
disable_mlock = true
