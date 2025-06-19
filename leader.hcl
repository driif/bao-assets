storage "raft" {
  path    = "./data-primary"
  node_id = "primary"
}

listener "tcp" {
  address = "127.0.0.1:8200"
  tls_disable = true
  cluster_address = "127.0.0.1:8201"
}

cluster_addr = "http://127.0.0.1:8201"
api_addr = "http://127.0.0.1:8200"

ui = false
log_level = "Debug"
disable_mlock = true
