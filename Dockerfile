FROM amazonlinux:2

# Update the system and install necessary packages
RUN yum update -y && \
    yum install -y shadow-utils maven awscli java-17-amazon-corretto jq yum-utils && \
    yum-config-manager --add-repo https://rpm.releases.hashicorp.com/AmazonLinux/hashicorp.repo && \
    yum -y install terraform && \
    yum clean all

# Create a non-root user
RUN useradd -m -s /bin/bash flinkuser

# Set the working directory
WORKDIR /home/flinkuser

# Change ownership of the working directory
RUN chown -R flinkuser:flinkuser /home/flinkuser

# Switch to the non-root user
USER flinkuser

# Add HEALTHCHECK instruction
HEALTHCHECK --interval=30s --timeout=30s --start-period=5s --retries=3 \
  CMD curl -f http://localhost/ || exit 1


