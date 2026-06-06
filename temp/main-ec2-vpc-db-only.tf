terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
     }
  }
}


provider "aws" {
  region = "us-east-1"
}

module "vpc" {
  source = "terraform-aws-modules/vpc/aws"

  name = "myRSVP"

  cidr = "10.0.0.0/16"

  azs             = ["us-east-1a", "us-east-1b"]
  public_subnets  = ["10.0.1.0/24", "10.0.2.0/24"]

  manage_default_security_group = true
  default_security_group_ingress = [
    {
      from_port   = 80
      to_port     = 80
      protocol    = "tcp"
      description = "Allow HTTP"
      cidr_blocks = "0.0.0.0/0"
    },
    {
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      description = "Allow SSH"
      cidr_blocks = "0.0.0.0/0"
    }
  ]
  default_security_group_egress = [
    {
      from_port   = 0
      to_port     = 0
      protocol    = "-1"
      cidr_blocks = "0.0.0.0/0"
    }
  ]

  tags = {
    Owner = "RSVP"
    Environment = "dev"
  }
}

resource "aws_dynamodb_table" "rsvp_table" {
  name         = "RSVP"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "phone"

  attribute {
    name = "phone"
    type = "S" # S = String
  }

  tags = {
    Description = "Create DynamoDB table RSVP"
  }
}
resource "aws_instance" "rsvp_web" {
  ami                         = "ami-0c7217cdde317cfec" # Amazon Linux 2023 in us-east-1
  instance_type               = "t2.micro"
  subnet_id                   = module.vpc.public_subnets[0]
  vpc_security_group_ids      = [module.vpc.default_security_group_id]
  associate_public_ip_address = true

  user_data = <<-EOF
              #!/bin/bash
              # Update and install Apache
              sudo apt update
              sudo apt install -y apache2
              sudo systemctl enable apache2
              sudo systemctl start apache2

              # Create the RSVP HTML file
              cat <<'INNER_EOF' > /var/www/html/index.html
              <!DOCTYPE html>
              <html lang="he" dir="rtl">
              <head>
              <meta charset="UTF-8">
              <meta name="viewport" content="width=device-width, initial-scale=1.0">
              <title>אישור הגעה לחתונה 💍</title>
              <style>
              body { font-family: "Rubik", sans-serif; background: linear-gradient(180deg, #fff8f0 0%, #fff0e0 100%); display: flex; flex-direction: column; align-items: center; justify-content: center; min-height: 100vh; margin: 0; }
              h1 { color: #5b3a29; font-size: 28px; margin-bottom: 10px; }
              p.subtitle { color: #7a5f4b; margin-bottom: 25px; font-size: 16px; }
              form { background-color: white; padding: 35px; border-radius: 20px; box-shadow: 0 8px 20px rgba(0,0,0,0.1); width: 90%; max-width: 420px; }
              label { font-weight: 600; display: block; margin-top: 15px; color: #4a2c2a; }
              input, select { width: 100%; padding: 10px; margin-top: 5px; border-radius: 8px; border: 1px solid #ddd; font-size: 16px; background-color: #fafafa; transition: border-color 0.3s; }
              input:focus, select:focus { outline: none; border-color: #d4a373; }
              button { width: 100%; padding: 12px; margin-top: 25px; background-color: #d4a373; color: white; font-size: 18px; font-weight: bold; border: none; border-radius: 8px; cursor: pointer; transition: background-color 0.3s; }
              button:hover { background-color: #c1824e; }
              #message { margin-top: 20px; font-weight: bold; text-align: center; font-size: 16px; }
              </style>
              </head>
              <body>
              <h1>אישור הגעה לחתונה 💌</h1>
              <p class="subtitle">אנא מלאו את הפרטים שלכם כדי שנוכל להיערך בהתאם 🎉</p>
              <form id="rsvpForm">
              <label for="fullName">שם מלא:</label>
              <input type="text" id="fullName" name="fullName" required>
              <label for="phone">טלפון:</label>
              <input type="tel" id="phone" name="phone" required>
              <label for="guests">מספר אורחים נוספים:</label>
              <input type="number" id="guests" name="guests" min="0" value="0">
              <label for="attendance">האם תגיעו?</label>
              <select id="attendance" name="attendance" required>
              <option value="">בחר</option>
              <option value="כן">כן</option>
              <option value="לא">לא</option>
              </select>
              <button type="submit">שלח RSVP</button>
              </form>
              <div id="message"></div>
              <script>
              document.getElementById("rsvpForm").addEventListener("submit", async function(e) {
              e.preventDefault();
              const fullName = document.getElementById("fullName").value.trim();
              const phone = document.getElementById("phone").value.trim();
              const guests = document.getElementById("guests").value.trim();
              const attendance = document.getElementById("attendance").value;
              const messageBox = document.getElementById("message");
              if (!fullName || !phone || !attendance) {
              messageBox.textContent = "אנא מלא את כל השדות.";
              messageBox.style.color = "red";
              return;
              }
              const data = { name: fullName, phone: phone, guests: parseInt(guests), attending: attendance === "כן" };
              try {
              const response = await fetch("https://ph1cu2qpna.execute-api.us-east-1.amazonaws.com/RSVP", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(data) });
              if (response.ok) {
              messageBox.textContent = "💐 הטופס נשלח בהצלחה! תודה על האישור 💐";
              messageBox.style.color = "green";
              document.getElementById("rsvpForm").reset();
              } else {
              messageBox.textContent = "שגיאה בשליחת הנתונים לשרת. אנא נסה שוב.";
              messageBox.style.color = "red";
              }
              } catch (err) {
              console.error(err);
              messageBox.textContent = "שגיאה בחיבור לשרת. אנא בדוק את החיבור שלך.";
              messageBox.style.color = "red";
              }
              });
              </script>
              </body>
              </html>
              INNER_EOF

              # Set permissions and restart
              sudo chown -R www-data:www-data /var/www/html
              chmod -R 755 /var/www/html
              systemctl restart apache2
              EOF

  tags = {
    Name = "RSVP-Web-Server"
  }
}

output "website_address" {
  value = "http://${aws_instance.rsvp_web.public_ip}"
}