# Setting Up Your Wallaroo Development Environment using Wallaroo Up

Wallaroo Up has been tested on Ubuntu Artful/Bionic/Trusty/Xenial, Fedora 26/27/28, CentOS 7, Debian Jessie/Stretch/Buster (Testing), Oracle Linux 7, and Amazon Linux 2 releases. It should also work on Red Hat Enterprise Linux 7.

## Memory requirements

In order to compile the Wallaroo example applications, your system will need to have approximately 3 GB working memory (this can be RAM or swap). If you don't have enough memory, you are likely to see that the compile process is `Killed` by the OS.

## Download Wallaroo Up script

```bash
curl https://raw.githubusercontent.com/WallarooLabs/wallaroo/{{ book.wallaroo_version }}/misc/wallaroo-up.sh -o /tmp/wallaroo-up.sh -J -L
```

## Run the Wallaroo Up script

The `-t golang` argument is required for a Go environment installation. The `-p <PATH>` argument is optional and can be used to control where the Wallaroo tutorial is installed into (the default is `~/wallaroo-tutorial`).

The script will require superuser privileges via `sudo` and will throw an error if `sudo` is not available. The script will prompt you prior to making any changes. It can optionally print out the commands it will run.

```bash
bash /tmp/wallaroo-up.sh -t golang
```

Follow the prompts to have Wallaroo Up install and configure Wallaroo and its dependencies.

Once Wallaroo Up has finished installing and configuring Wallaroo for your environment, it will also create an `activate` script that can be used to set up the appropriate environment variables.

## Register

Register today and receive a Wallaroo T-shirt and a one-hour phone consultation with Sean, our V.P. of Engineering, to discuss your streaming data questions. Not sure if you have a streaming data problem? Not sure how to go about architecting a streaming data system? Looking to improve an existing system? Not sure how Wallaroo can help? Sean has extensive experience and is happy to help you work through your questions.

Please register here: [https://www.wallaroolabs.com/register](https://www.wallaroolabs.com/register).

Your email address will only be used to facilitate the above.

## Conclusion

Awesome! All set. Time to try running your first application.
