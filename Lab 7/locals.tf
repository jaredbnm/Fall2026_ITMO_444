locals {
  # One entry per tier. Everything that exists once per tier is created from this map with for_each,
  # so adding a third tier means adding a third entry here.
  tiers = {
    weather = { listener_port = 8080 }
    advisor = { listener_port = 8081 }
  }

  app_port = 3000
}