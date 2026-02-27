I want to add user management to the accounting system with following features:
* Every account has owner (createdBy)
* Every transaction has createdBy
* Owner can be user only
* Role based permissions (Owner, Editor, Viewer)
* User can login with password or oauth2 (ex. google)
* It is possible to link existing User login + password with oauth2 auth, it should be same User account
* It is ONLY possible to transfer between accounts of same User or Group, or User to/from account belonging to Group, where user also exists
* Support following oauth2 providers: Google, Github, Microsoft
* Everyne can signup
* Telegram bot will be available to support all main app flows like: 
  - signup
  - list accounts
  - transfer
  - link existing account