request = function()
  upperCase = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
  wrk.headers["Connection"] = "Keep-Alive"
  rand = math.random(#upperCase)
  rand2 = math.random(#upperCase)
  path = "/api/users/search/?first_name=" .. string.sub(upperCase, rand, rand) .. "&last_name=" .. string.sub(upperCase, rand2, rand2)
  return wrk.format("GET", path)
end