# Exoid Router

Create Exoid compatible APIs

```coffee
router = require 'exoid-router'

UserCtrl = require './controllers/user'
AuthCtrl = require './controllers/auth'

authed = (handler) ->
  unless handler?
    return null

  (body, req, rest...) ->
    unless req.user?
      router.throw status: 401, info: 'Unauthorized'

    handler body, req, rest...

routes = router
###################
# Public Routes   #
###################
.on 'auth.login', AuthCtrl.login

###################
# Authed Routes   #
###################
.on 'users.getMe', authed UserCtrl.getMe

# As Express Middleware
app.post '/exoid', routes.asMiddleware()

# Resolve (v0.2.4+)
routes.resolve path, body, req)
.then ({result, error, cache}) -> null
```
