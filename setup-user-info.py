#!/usr/bin/env python

import sys
import subprocess
from keystoneclient.auth.identity import v2
from keystoneclient import session
from novaclient.client import Client

#import keystoneclient
#import novaclient

with open('/root/setup/settings','r') as file:
    content = file.read()
    pass

exec(content)

blob = subprocess.check_output(["/usr/bin/geni-get","geni_user"])
if blob.endswith('\n'):
    exec("ui = %s" % (blob[0:-1],))
else:
    exec("ui = %s" % (blob,))
    pass

url = 'http://%s:5000/v2.0' % (CONTROLLER,)
auth = v2.Password(auth_url=url,username='admin',password=ADMIN_PASS,tenant_name='admin')
sess = session.Session(auth=auth)
nova = Client(2,session=sess)

for key in ui[0]['keys']:
    posn = key.rindex(' ')
    name = key[posn+1:]
    rname = ""
    for c in name:
        if c.isalpha():
            rname += c
        else:
            rname += 'X'
        pass
    try:
        nova.keypairs.create(rname,key)
    except:
        pass
    pass

sys.exit(0)
